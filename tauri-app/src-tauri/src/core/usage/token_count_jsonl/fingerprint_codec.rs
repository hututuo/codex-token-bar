use std::fmt;

pub(super) const FINGERPRINT_VERSION: u8 = 1;
pub(super) const FINGERPRINT_VALUE_COUNT: usize = 11;
pub(super) const LEGACY_FIXED_WIDTH_BYTE_COUNT: usize =
    FINGERPRINT_VALUE_COUNT * std::mem::size_of::<u64>();

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum FingerprintCodecError {
    UnsupportedVersion(u8),
    Truncated,
    Overflow,
    NonCanonical,
    TrailingBytes,
    InvalidBoolean(u64),
    InvalidLegacyText,
    InvalidLegacyFixedWidth(usize),
}

impl fmt::Display for FingerprintCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for FingerprintCodecError {}

pub(super) fn encode(
    values: &[u64; FINGERPRINT_VALUE_COUNT],
) -> Result<Vec<u8>, FingerprintCodecError> {
    validate_fingerprint_values(values)?;
    let mut encoded = Vec::with_capacity(1 + values.len() * 2);
    encoded.push(FINGERPRINT_VERSION);
    for value in values {
        encode_uleb128(*value, &mut encoded);
    }
    Ok(encoded)
}

pub(super) fn decode(
    encoded: &[u8],
) -> Result<[u64; FINGERPRINT_VALUE_COUNT], FingerprintCodecError> {
    let Some(version) = encoded.first().copied() else {
        return Err(FingerprintCodecError::Truncated);
    };
    if version != FINGERPRINT_VERSION {
        return Err(FingerprintCodecError::UnsupportedVersion(version));
    }

    let mut offset = 1;
    let mut values = [0_u64; FINGERPRINT_VALUE_COUNT];
    for value in &mut values {
        *value = decode_uleb128(encoded, &mut offset)?;
    }
    if offset != encoded.len() {
        return Err(FingerprintCodecError::TrailingBytes);
    }
    validate_fingerprint_values(&values)?;
    Ok(values)
}

pub(super) fn decode_legacy_text(
    encoded: &str,
) -> Result<[u64; FINGERPRINT_VALUE_COUNT], FingerprintCodecError> {
    let fields = encoded.split(':').collect::<Vec<_>>();
    if fields.len() != FINGERPRINT_VALUE_COUNT {
        return Err(FingerprintCodecError::InvalidLegacyText);
    }
    let mut values = [0_u64; FINGERPRINT_VALUE_COUNT];
    for (target, field) in values.iter_mut().zip(fields) {
        if field.is_empty() {
            return Err(FingerprintCodecError::InvalidLegacyText);
        }
        *target = field
            .parse::<u64>()
            .map_err(|_| FingerprintCodecError::InvalidLegacyText)?;
        if field != target.to_string() {
            return Err(FingerprintCodecError::InvalidLegacyText);
        }
    }
    validate_fingerprint_values(&values)?;
    Ok(values)
}

pub(super) fn decode_legacy_fixed_width(
    encoded: &[u8],
) -> Result<[u64; FINGERPRINT_VALUE_COUNT], FingerprintCodecError> {
    if encoded.len() != LEGACY_FIXED_WIDTH_BYTE_COUNT {
        return Err(FingerprintCodecError::InvalidLegacyFixedWidth(
            encoded.len(),
        ));
    }
    let mut values = [0_u64; FINGERPRINT_VALUE_COUNT];
    for (target, field) in values.iter_mut().zip(encoded.chunks_exact(8)) {
        *target = u64::from_le_bytes(field.try_into().expect("eight-byte chunk"));
    }
    validate_fingerprint_values(&values)?;
    Ok(values)
}

fn validate_fingerprint_values(
    values: &[u64; FINGERPRINT_VALUE_COUNT],
) -> Result<(), FingerprintCodecError> {
    if values[5] > 1 {
        return Err(FingerprintCodecError::InvalidBoolean(values[5]));
    }
    Ok(())
}

fn encode_uleb128(mut value: u64, encoded: &mut Vec<u8>) {
    loop {
        let mut byte = (value & 0x7F) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        encoded.push(byte);
        if value == 0 {
            break;
        }
    }
}

fn decode_uleb128(encoded: &[u8], offset: &mut usize) -> Result<u64, FingerprintCodecError> {
    let mut value = 0_u64;
    let mut shift = 0_u32;
    let mut byte_count = 0_u8;

    loop {
        let byte = *encoded
            .get(*offset)
            .ok_or(FingerprintCodecError::Truncated)?;
        *offset += 1;
        byte_count += 1;
        let payload = u64::from(byte & 0x7F);
        if shift >= 64 || (shift == 63 && payload > 1) {
            return Err(FingerprintCodecError::Overflow);
        }
        value |= payload << shift;

        if byte & 0x80 == 0 {
            if byte_count > 1 && payload == 0 {
                return Err(FingerprintCodecError::NonCanonical);
            }
            return Ok(value);
        }
        if byte_count >= 10 {
            return Err(FingerprintCodecError::Overflow);
        }
        shift += 7;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIXED_VALUES: [u64; FINGERPRINT_VALUE_COUNT] = [
        1,
        127,
        128,
        255,
        300,
        1,
        16_384,
        u32::MAX as u64,
        u64::MAX,
        42,
        0,
    ];

    #[test]
    fn canonical_golden_vectors_match_cross_platform_contract() {
        assert_eq!(
            hex(&encode(&[0; FINGERPRINT_VALUE_COUNT]).unwrap()),
            "010000000000000000000000"
        );
        assert_eq!(
            hex(&encode(&MIXED_VALUES).unwrap()),
            "01017f8001ff01ac0201808001ffffffff0fffffffffffffffffff012a00"
        );
        assert_eq!(
            decode(&encode(&MIXED_VALUES).unwrap()).unwrap(),
            MIXED_VALUES
        );
    }

    #[test]
    fn reasoning_difference_and_legacy_encodings_remain_exact() {
        let mut without_reasoning = [0_u64; FINGERPRINT_VALUE_COUNT];
        without_reasoning[0] = 100;
        let mut with_reasoning = without_reasoning;
        with_reasoning[3] = 1;
        assert_ne!(
            encode(&without_reasoning).unwrap(),
            encode(&with_reasoning).unwrap()
        );

        let legacy_text = MIXED_VALUES
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(":");
        assert_eq!(decode_legacy_text(&legacy_text).unwrap(), MIXED_VALUES);

        let legacy_fixed = MIXED_VALUES
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect::<Vec<_>>();
        assert_eq!(
            decode_legacy_fixed_width(&legacy_fixed).unwrap(),
            MIXED_VALUES
        );
        assert_eq!(
            hex(&encode(&decode_legacy_fixed_width(&legacy_fixed).unwrap()).unwrap()),
            "01017f8001ff01ac0201808001ffffffff0fffffffffffffffffff012a00"
        );
    }

    #[test]
    fn decoder_rejects_noncanonical_overflow_and_trailing_bytes() {
        let mut overlong = vec![FINGERPRINT_VERSION, 0x80, 0x00];
        overlong.extend([0; 10]);
        assert_eq!(decode(&overlong), Err(FingerprintCodecError::NonCanonical));

        let mut overflow = vec![FINGERPRINT_VERSION];
        overflow.extend([0xFF; 10]);
        overflow.extend([0; 10]);
        assert_eq!(decode(&overflow), Err(FingerprintCodecError::Overflow));

        let mut trailing = encode(&[0; FINGERPRINT_VALUE_COUNT]).unwrap();
        trailing.push(0);
        assert_eq!(decode(&trailing), Err(FingerprintCodecError::TrailingBytes));

        let mut invalid_boolean = [0_u64; FINGERPRINT_VALUE_COUNT];
        invalid_boolean[5] = 2;
        assert_eq!(
            encode(&invalid_boolean),
            Err(FingerprintCodecError::InvalidBoolean(2))
        );
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}
