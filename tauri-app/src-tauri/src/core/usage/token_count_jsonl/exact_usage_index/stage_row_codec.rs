//! Lossless encoding for private SQLite staging rows.
//!
//! Text is kept as SQLite's raw byte sequence. In particular, this codec does
//! not require valid UTF-8 and does not treat an embedded NUL as a terminator.

use rusqlite::{
    types::{ToSql, ToSqlOutput, Value, ValueRef},
    Row,
};
use std::{error::Error, fmt};

const MAGIC: [u8; 4] = [0x54, 0x42, 0x52, 0x01];
const HEADER_BYTES: usize = 8;
const COLUMN_HEADER_BYTES: usize = 9;
const MAX_COLUMNS: usize = 64;
const MAX_ROW_BYTES: usize = 16 * 1024 * 1024;

/// A decoded SQLite value that preserves the payload bytes used by the codec.
#[derive(Clone, Debug, PartialEq)]
pub(super) enum OwnedCell {
    Integer([u8; 8]),
    Real([u8; 8]),
    Text(Vec<u8>),
    Blob(Vec<u8>),
    Null,
}

impl ToSql for OwnedCell {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(match self {
            Self::Integer(bytes) => ToSqlOutput::Owned(Value::Integer(i64::from_be_bytes(*bytes))),
            Self::Real(bytes) => {
                ToSqlOutput::Owned(Value::Real(f64::from_bits(u64::from_be_bytes(*bytes))))
            }
            Self::Text(bytes) => ToSqlOutput::Borrowed(ValueRef::Text(bytes)),
            Self::Blob(bytes) => ToSqlOutput::Borrowed(ValueRef::Blob(bytes)),
            Self::Null => ToSqlOutput::Owned(Value::Null),
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CodecError;

impl fmt::Display for CodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("invalid exact stage row")
    }
}

impl Error for CodecError {}

/// Encode every column in a rusqlite row using the Swift codec's canonical
/// storage-class bytes.
pub(super) fn encode_row(row: &Row<'_>) -> Result<Vec<u8>, CodecError> {
    let column_count = row.as_ref().column_count();
    if !(1..=MAX_COLUMNS).contains(&column_count) {
        return Err(CodecError);
    }

    let mut encoded = Vec::with_capacity(HEADER_BYTES);
    encoded.extend_from_slice(&MAGIC);
    encoded.extend_from_slice(
        &u32::try_from(column_count)
            .map_err(|_| CodecError)?
            .to_be_bytes(),
    );

    for index in 0..column_count {
        let value = row.get_ref(index).map_err(|_| CodecError)?;
        append_value(&mut encoded, value)?;
    }
    Ok(encoded)
}

/// Encode an ordered set of rusqlite values when a caller already has
/// `ValueRef`s rather than a `Row`.
pub(super) fn encode_value_refs<'value>(
    values: &[ValueRef<'value>],
) -> Result<Vec<u8>, CodecError> {
    if !(1..=MAX_COLUMNS).contains(&values.len()) {
        return Err(CodecError);
    }

    let mut encoded = Vec::with_capacity(HEADER_BYTES);
    encoded.extend_from_slice(&MAGIC);
    encoded.extend_from_slice(
        &u32::try_from(values.len())
            .map_err(|_| CodecError)?
            .to_be_bytes(),
    );
    for value in values {
        append_value(&mut encoded, *value)?;
    }
    Ok(encoded)
}

fn append_value(encoded: &mut Vec<u8>, value: ValueRef<'_>) -> Result<(), CodecError> {
    let (type_byte, payload): (u8, &[u8]) = match value {
        ValueRef::Integer(integer) => (1, &integer.to_be_bytes()),
        ValueRef::Real(real) => (2, &real.to_bits().to_be_bytes()),
        ValueRef::Text(bytes) => (3, bytes),
        ValueRef::Blob(bytes) => (4, bytes),
        ValueRef::Null => (5, &[]),
    };

    let new_len = encoded
        .len()
        .checked_add(COLUMN_HEADER_BYTES)
        .and_then(|length| length.checked_add(payload.len()))
        .ok_or(CodecError)?;
    if new_len > MAX_ROW_BYTES {
        return Err(CodecError);
    }

    encoded.push(type_byte);
    encoded.extend_from_slice(
        &u64::try_from(payload.len())
            .map_err(|_| CodecError)?
            .to_be_bytes(),
    );
    encoded.extend_from_slice(payload);
    Ok(())
}

/// Decode a row and require the caller's expected column count to match the
/// count stored in the row header.
pub(super) fn decode_row(
    encoded: &[u8],
    expected_columns: usize,
) -> Result<Vec<OwnedCell>, CodecError> {
    if !(1..=MAX_COLUMNS).contains(&expected_columns)
        || encoded.len() < HEADER_BYTES
        || encoded.len() > MAX_ROW_BYTES
        || encoded[..4] != MAGIC
    {
        return Err(CodecError);
    }

    let column_count =
        u32::from_be_bytes(encoded[4..8].try_into().map_err(|_| CodecError)?) as usize;
    if column_count != expected_columns {
        return Err(CodecError);
    }

    let mut position = HEADER_BYTES;
    let mut cells = Vec::with_capacity(expected_columns);
    for _ in 0..expected_columns {
        let header_end = position
            .checked_add(COLUMN_HEADER_BYTES)
            .ok_or(CodecError)?;
        if header_end > encoded.len() {
            return Err(CodecError);
        }

        let type_byte = encoded[position];
        let payload_len = u64::from_be_bytes(
            encoded[position + 1..header_end]
                .try_into()
                .map_err(|_| CodecError)?,
        );
        position = header_end;

        let payload_len = usize::try_from(payload_len).map_err(|_| CodecError)?;
        let payload_end = position.checked_add(payload_len).ok_or(CodecError)?;
        if payload_end > encoded.len() {
            return Err(CodecError);
        }
        let payload = &encoded[position..payload_end];

        let cell = match type_byte {
            1 if payload.len() == 8 => {
                OwnedCell::Integer(payload.try_into().map_err(|_| CodecError)?)
            }
            2 if payload.len() == 8 => OwnedCell::Real(payload.try_into().map_err(|_| CodecError)?),
            3 => OwnedCell::Text(payload.to_vec()),
            4 => OwnedCell::Blob(payload.to_vec()),
            5 if payload.is_empty() => OwnedCell::Null,
            _ => return Err(CodecError),
        };

        cells.push(cell);
        position = payload_end;
    }

    if position != encoded.len() {
        return Err(CodecError);
    }
    Ok(cells)
}

#[cfg(test)]
mod tests {
    use super::{decode_row, encode_row, encode_value_refs, CodecError, OwnedCell};
    use rusqlite::{params_from_iter, Connection};
    use serde_json::Value as JsonValue;
    use sha2::{Digest, Sha256};

    const FIXTURE_JSON: &str =
        include_str!("../../../../../../../spec/fixtures/exact-stage-row-v1.json");

    fn decode_hex(text: &str) -> Vec<u8> {
        assert_eq!(text.len() % 2, 0, "hex string must have whole bytes");
        text.as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let digit = |byte| match byte {
                    b'0'..=b'9' => byte - b'0',
                    b'a'..=b'f' => byte - b'a' + 10,
                    b'A'..=b'F' => byte - b'A' + 10,
                    _ => panic!("invalid hexadecimal byte"),
                };
                (digit(pair[0]) << 4) | digit(pair[1])
            })
            .collect()
    }

    fn fixture() -> JsonValue {
        serde_json::from_str(FIXTURE_JSON).expect("shared row fixture should be valid JSON")
    }

    fn fixture_cells(columns: &[JsonValue]) -> Vec<OwnedCell> {
        columns
            .iter()
            .map(|column| {
                let payload = decode_hex(column["payloadHex"].as_str().unwrap());
                match column["type"].as_str().unwrap() {
                    "INTEGER" => OwnedCell::Integer(payload.try_into().unwrap()),
                    "REAL" => OwnedCell::Real(payload.try_into().unwrap()),
                    "TEXT" => OwnedCell::Text(payload),
                    "BLOB" => OwnedCell::Blob(payload),
                    "NULL" => {
                        assert!(payload.is_empty());
                        OwnedCell::Null
                    }
                    other => panic!("unsupported fixture storage class: {other}"),
                }
            })
            .collect()
    }

    #[test]
    fn shared_valid_vector_decodes_and_reencodes_identically() {
        let document = fixture();
        let vector = &document["validRows"][0];
        let expected_columns = vector["expectedColumns"].as_u64().unwrap() as usize;
        let bytes = decode_hex(vector["rowHex"].as_str().unwrap());
        let digest = Sha256::digest(&bytes);
        let digest_hex = digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert_eq!(digest_hex, vector["sha256"].as_str().unwrap());

        let decoded = decode_row(&bytes, expected_columns).unwrap();
        let columns = vector["columns"].as_array().unwrap();
        assert_eq!(decoded, fixture_cells(columns));

        // Passing the raw cells through rusqlite's binding and ValueRef APIs
        // exercises both ToSql preservation and the row encoder. This is a
        // parameter SELECT, not a claim about table-affinity normalization.
        let placeholders = (1..=expected_columns)
            .map(|index| format!("?{index}"))
            .collect::<Vec<_>>()
            .join(", ");
        let connection = Connection::open_in_memory().unwrap();
        let mut statement = connection
            .prepare(&format!("SELECT {placeholders}"))
            .unwrap();
        let mut rows = statement.query(params_from_iter(decoded.iter())).unwrap();
        let row = rows.next().unwrap().unwrap();
        assert_eq!(encode_row(row).unwrap(), bytes);
        let value_refs = (0..expected_columns)
            .map(|index| row.get_ref(index).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(encode_value_refs(&value_refs).unwrap(), bytes);
    }

    #[test]
    fn shared_invalid_vectors_are_rejected() {
        let document = fixture();
        for vector in document["invalidRows"].as_array().unwrap() {
            let bytes = decode_hex(vector["rowHex"].as_str().unwrap());
            let digest = Sha256::digest(&bytes);
            let digest_hex = digest
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            assert_eq!(digest_hex, vector["sha256"].as_str().unwrap());
            let expected_columns = vector["expectedColumns"].as_u64().unwrap() as usize;
            assert_eq!(decode_row(&bytes, expected_columns), Err(CodecError));
        }
    }

    #[test]
    fn decoder_enforces_column_count_and_row_size() {
        let document = fixture();
        let bytes = decode_hex(document["validRows"][0]["rowHex"].as_str().unwrap());
        assert_eq!(decode_row(&bytes, 10), Err(CodecError));
        assert_eq!(decode_row(&bytes, 65), Err(CodecError));

        let oversized = vec![0; 16 * 1024 * 1024 + 1];
        assert_eq!(decode_row(&oversized, 1), Err(CodecError));
    }
}
