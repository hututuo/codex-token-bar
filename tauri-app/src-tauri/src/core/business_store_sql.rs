//! SQL name binding for private legacy-store partitions.
//!
//! Only SQL identifiers are rewritten. Literals, comments, and bind parameters
//! are preserved byte-for-byte so data values never become table names.

use std::collections::{HashMap, HashSet};
use std::ffi::CString;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum BindingError {
    MalformedSql,
    InvalidStoreId,
    InvalidUserVersion,
    ReadOnlyAttachedStore,
    WholeContainerVacuum,
    GlobalPragmaDenied,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum TokenKind {
    Identifier,
    String,
    Parameter,
    Trivia,
    Punctuation,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Token {
    kind: TokenKind,
    raw: String,
    value: String,
}

#[derive(Clone, Debug)]
pub(crate) struct SQLiteStoreNamespace {
    prefix: String,
    object_names: HashSet<String>,
    temporary_object_names: HashSet<String>,
    temporary_namespace_enabled: bool,
}

/// Module-aware SQL binder. It keeps `PRAGMA user_version` inside the
/// container's per-store metadata row instead of changing container A's PRAGMA.
pub(crate) struct StoreSqlBinding {
    store_id: String,
    namespace: SQLiteStoreNamespace,
    attached: HashMap<String, SQLiteStoreNamespace>,
}

impl StoreSqlBinding {
    pub(crate) fn new(
        store_id: impl Into<String>,
        prefix: impl Into<String>,
        object_names: impl IntoIterator<Item = String>,
    ) -> Result<Self, BindingError> {
        let store_id = store_id.into();
        if store_id.len() != 64
            || !store_id
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(BindingError::InvalidStoreId);
        }
        let prefix = prefix.into();
        if prefix != format!("s{store_id}_") {
            return Err(BindingError::InvalidStoreId);
        }
        Ok(Self {
            store_id,
            namespace: SQLiteStoreNamespace::new(prefix, object_names),
            attached: HashMap::new(),
        })
    }

    /// Bind one SQL statement, rewriting the module-local user_version PRAGMA
    /// into a query/update of `tb_stores`; all other SQL goes through the
    /// identifier-only namespace binder.
    pub(crate) fn sql(&mut self, sql: &str) -> Result<String, BindingError> {
        let mut output = String::new();
        for statement in split_complete_statements(sql)? {
            if statement.trim().is_empty() {
                continue;
            }
            // `split_complete_statements` includes each statement's delimiter.
            // Strip that one outer delimiter before joining normalized output;
            // delimiters inside trigger bodies remain untouched.
            let statement = statement.trim_end();
            let statement = statement.strip_suffix(';').unwrap_or(statement);
            let bound = self.bind_one(statement)?;
            if bound.trim().is_empty() {
                continue;
            }
            if !output.is_empty() {
                output.push(';');
            }
            output.push_str(&bound);
        }
        Ok(output)
    }

    pub(crate) fn set_temporary_namespace_enabled(&mut self, enabled: bool) {
        self.namespace.set_temporary_namespace_enabled(enabled);
    }

    fn bind_one(&mut self, sql: &str) -> Result<String, BindingError> {
        let first_word = tokenize(sql)?
            .into_iter()
            .find(|token| token.kind != TokenKind::Trivia)
            .map(|token| token.value.to_ascii_uppercase());
        if first_word.as_deref() == Some("VACUUM") {
            let has_into = tokenize(sql)?.iter().any(|token| {
                token.kind == TokenKind::Identifier && token.value.eq_ignore_ascii_case("INTO")
            });
            return if has_into {
                Err(BindingError::WholeContainerVacuum)
            } else {
                // A module-local VACUUM used to compact an isolated file.
                // The routed connection shares A, so only the container's
                // throttled maintenance path may reclaim its free pages.
                Ok(String::new())
            };
        }
        if references_attached_store_write(sql, &self.attached)? {
            return Err(BindingError::ReadOnlyAttachedStore);
        }
        let tokens = tokenize(sql)?;
        let significant: Vec<&Token> = tokens
            .iter()
            .filter(|token| token.kind != TokenKind::Trivia)
            .collect();
        let pragma_name_position = if significant
            .first()
            .is_some_and(|token| token.value.eq_ignore_ascii_case("PRAGMA"))
        {
            if significant.get(2).is_some_and(|token| token.value == ".") {
                Some(3)
            } else {
                Some(1)
            }
        } else {
            None
        };
        if pragma_name_position == Some(3) {
            if let Some(namespace) = self
                .attached
                .get(&significant[1].value.to_ascii_lowercase())
            {
                let name = significant[3].value.to_ascii_lowercase();
                let allowed = [
                    "table_info",
                    "table_xinfo",
                    "index_info",
                    "index_xinfo",
                    "index_list",
                    "foreign_key_list",
                ];
                if significant.len() != 7
                    || !allowed.contains(&name.as_str())
                    || significant[4].value != "("
                    || significant[6].value != ")"
                    || !namespace.has_object(&significant[5].value)
                {
                    return Err(BindingError::ReadOnlyAttachedStore);
                }
                return Ok(format!(
                    "PRAGMA main.{name}({})",
                    SQLiteStoreNamespace::quote(&namespace.physical(&significant[5].value))
                ));
            }
        }
        if let Some(position) = pragma_name_position {
            let name = significant
                .get(position)
                .map(|token| token.value.to_ascii_lowercase())
                .unwrap_or_default();
            let is_assignment = significant
                .iter()
                .any(|token| token.value == "=" || token.value == "(");
            if name == "wal_checkpoint" {
                return Ok("SELECT 0 AS busy,0 AS log,0 AS checkpointed".to_string());
            }
            if name == "journal_mode" && is_assignment {
                // Legacy module initializers may request WAL/DELETE. Only the
                // container owner may change it; report its current mode.
                return Ok("PRAGMA main.journal_mode".to_string());
            }
            if name == "temp_store" && is_assignment {
                // Bound connections establish FILE mode before creating their
                // logical catalog views. A module cannot change it afterward,
                // because SQLite would discard those temp views.
                return Ok(String::new());
            }
        }
        if pragma_name_position.is_some_and(|position| {
            significant
                .get(position)
                .is_some_and(|token| token.value.eq_ignore_ascii_case("user_version"))
        }) {
            if let Some(equal) = significant.iter().position(|token| token.value == "=") {
                let literal = significant
                    .get(equal + 1..)
                    .ok_or(BindingError::InvalidUserVersion)?
                    .iter()
                    .take_while(|token| token.value != ";")
                    .map(|token| token.raw.as_str())
                    .collect::<String>();
                let value = literal
                    .parse::<i64>()
                    .map_err(|_| BindingError::InvalidUserVersion)?;
                if value < 0 {
                    return Err(BindingError::InvalidUserVersion);
                }
                return Ok(format!(
                    "UPDATE main.tb_stores SET user_version={value} WHERE store_id='{}'",
                    self.store_id
                ));
            }
            return Ok(format!(
                "SELECT user_version FROM main.tb_stores WHERE store_id='{}'",
                self.store_id
            ));
        }
        if significant
            .first()
            .is_some_and(|token| token.value.eq_ignore_ascii_case("PRAGMA"))
            && significant
                .iter()
                .any(|token| token.value.eq_ignore_ascii_case("foreign_key_check"))
            && !significant.iter().any(|token| token.value == "(")
        {
            let prefix = self.namespace.prefix();
            return Ok(format!(
                "SELECT * FROM pragma_foreign_key_check WHERE substr(\"table\",1,{})='{}'",
                prefix.len(),
                prefix
            ));
        }
        let bound = self.namespace.bind(sql)?;
        if self.attached.is_empty() {
            return Ok(bound);
        }
        let mut tokens = tokenize(&bound)?;
        for index in 0..tokens.len() {
            if tokens[index].kind != TokenKind::Identifier {
                continue;
            }
            let previous = (0..index)
                .rev()
                .find(|&position| tokens[position].kind != TokenKind::Trivia);
            let Some(dot) = previous.filter(|&position| tokens[position].value == ".") else {
                continue;
            };
            let schema_position = (0..dot)
                .rev()
                .find(|&position| tokens[position].kind != TokenKind::Trivia);
            let Some(schema_position) = schema_position else {
                continue;
            };
            let Some(namespace) = self
                .attached
                .get(&tokens[schema_position].value.to_ascii_lowercase())
            else {
                continue;
            };
            let logical = tokens[index]
                .value
                .strip_prefix(self.namespace.prefix())
                .unwrap_or(&tokens[index].value)
                .to_owned();
            if namespace.has_object(&logical) {
                tokens[schema_position].raw = "main".to_string();
                tokens[index].raw = SQLiteStoreNamespace::quote(&namespace.physical(&logical));
            }
        }
        Ok(tokens.into_iter().map(|token| token.raw).collect())
    }

    pub(crate) fn namespace(&self) -> &SQLiteStoreNamespace {
        &self.namespace
    }

    pub(crate) fn namespace_mut(&mut self) -> &mut SQLiteStoreNamespace {
        &mut self.namespace
    }

    pub(crate) fn register_attached_namespace(
        &mut self,
        alias: &str,
        prefix: String,
        object_names: impl IntoIterator<Item = String>,
    ) {
        self.attached.insert(
            alias.to_ascii_lowercase(),
            SQLiteStoreNamespace::new(prefix, object_names),
        );
    }

    pub(crate) fn unregister_attached_namespace(&mut self, alias: &str) {
        self.attached.remove(&alias.to_ascii_lowercase());
    }

    pub(crate) fn store_id(&self) -> &str {
        &self.store_id
    }

    pub(crate) fn prefix(&self) -> &str {
        self.namespace.prefix()
    }

    pub(crate) fn has_object(&self, logical_name: &str) -> bool {
        self.namespace
            .object_names
            .contains(&logical_name.to_ascii_lowercase())
    }
}

fn references_attached_store_write(
    sql: &str,
    attached: &HashMap<String, SQLiteStoreNamespace>,
) -> Result<bool, BindingError> {
    if attached.is_empty() {
        return Ok(false);
    }
    let tokens = tokenize(sql)?;
    let significant = tokens
        .iter()
        .filter(|token| token.kind != TokenKind::Trivia)
        .collect::<Vec<_>>();
    let first = significant
        .first()
        .map(|t| t.value.to_ascii_uppercase())
        .unwrap_or_default();
    Ok(significant.windows(2).enumerate().any(|(position, pair)| {
        if pair[0].kind != TokenKind::Identifier
            || !attached.contains_key(&pair[0].value.to_ascii_lowercase())
            || pair[1].value != "."
            || position == 0
        {
            return false;
        }
        let previous = significant[position - 1].value.to_ascii_uppercase();
        // INSERT INTO own_table SELECT ... FROM alias.table is a read of the
        // sealed stage. Reject its mutation targets, not every alias occurring
        // anywhere in a statement that also writes the destination module.
        matches!(
            previous.as_str(),
            "INTO" | "UPDATE" | "TABLE" | "VIEW" | "INDEX" | "TRIGGER"
        ) || (previous == "FROM" && first == "DELETE")
            || (previous == "ON" && first == "CREATE")
    }))
}

impl SQLiteStoreNamespace {
    pub(crate) fn new(
        prefix: impl Into<String>,
        object_names: impl IntoIterator<Item = String>,
    ) -> Self {
        Self {
            prefix: prefix.into(),
            object_names: object_names
                .into_iter()
                .map(|name| name.to_ascii_lowercase())
                .collect(),
            temporary_object_names: HashSet::new(),
            temporary_namespace_enabled: false,
        }
    }

    fn set_temporary_namespace_enabled(&mut self, enabled: bool) {
        self.temporary_namespace_enabled = enabled;
    }

    pub(crate) fn quote(identifier: &str) -> String {
        format!("\"{}\"", identifier.replace('"', "\"\""))
    }

    pub(crate) fn canonical_sql(sql: &str) -> Result<String, BindingError> {
        let tokens = tokenize(sql)?;
        let mut output = String::new();
        for token in tokens {
            match token.kind {
                TokenKind::Trivia => {}
                TokenKind::Identifier => {
                    let value = token.value.to_lowercase();
                    output.push_str(&format!("I{}:{};", value.len(), value));
                }
                TokenKind::String => {
                    output.push_str(&format!("S{}:{};", token.value.len(), token.value));
                }
                TokenKind::Punctuation | TokenKind::Parameter => {
                    output.push_str(&format!("P{}:{};", token.raw.len(), token.raw));
                }
            }
        }
        Ok(output)
    }

    pub(crate) fn is_without_rowid(sql: &str) -> Result<bool, BindingError> {
        let tokens = tokenize(sql)?;
        let significant = tokens
            .iter()
            .filter(|token| token.kind != TokenKind::Trivia)
            .collect::<Vec<_>>();
        Ok(significant.windows(2).any(|pair| {
            pair[0].kind == TokenKind::Identifier
                && pair[0].raw == pair[0].value
                && pair[0].value.eq_ignore_ascii_case("WITHOUT")
                && pair[1].kind == TokenKind::Identifier
                && pair[1].raw == pair[1].value
                && pair[1].value.eq_ignore_ascii_case("ROWID")
        }))
    }

    pub(crate) fn physical(&self, logical: &str) -> String {
        if let Some(suffix) = logical.strip_prefix("sqlite_autoindex_") {
            format!("sqlite_autoindex_{}{}", self.prefix, suffix)
        } else {
            format!("{}{}", self.prefix, logical)
        }
    }

    pub(crate) fn prefix(&self) -> &str {
        &self.prefix
    }

    pub(crate) fn has_object(&self, logical_name: &str) -> bool {
        self.object_names
            .contains(&logical_name.to_ascii_lowercase())
    }

    /// Bind object names discovered from existing schema plus objects created
    /// or renamed by this statement.
    pub(crate) fn bind(&mut self, sql: &str) -> Result<String, BindingError> {
        let mut tokens = tokenize(sql)?;
        let mut statement_start = 0;
        for end in 0..=tokens.len() {
            if end == tokens.len()
                || (tokens[end].kind == TokenKind::Punctuation && tokens[end].raw == ";")
            {
                let significant: Vec<usize> = (statement_start..end)
                    .filter(|&index| tokens[index].kind != TokenKind::Trivia)
                    .collect();
                self.register_statement(&tokens, &significant);
                bind_pragma_table_argument(
                    &mut tokens,
                    &significant,
                    &self.object_names,
                    &self.temporary_object_names,
                    self.temporary_namespace_enabled,
                    &self.prefix,
                );
                statement_start = end + 1;
            }
        }

        for index in 0..tokens.len() {
            if tokens[index].kind != TokenKind::Identifier {
                continue;
            }
            let value = tokens[index].value.clone();
            let lower = value.to_ascii_lowercase();
            if lower == "sqlite_master" || lower == "sqlite_schema" {
                let previous = (0..index)
                    .rev()
                    .find(|&position| tokens[position].kind != TokenKind::Trivia);
                if let Some(dot) = previous.filter(|&position| tokens[position].value == ".") {
                    let schema = (0..dot)
                        .rev()
                        .find(|&position| tokens[position].kind != TokenKind::Trivia);
                    if let Some(schema) = schema {
                        if tokens[schema].kind == TokenKind::Identifier
                            && matches!(
                                tokens[schema].value.to_ascii_lowercase().as_str(),
                                "main" | "temp"
                            )
                        {
                            tokens[schema].raw = "temp".to_string();
                            tokens[index].raw = Self::quote("tb_logical_catalog");
                            continue;
                        }
                    }
                }
                tokens[index].raw = format!("temp.{}", Self::quote("tb_logical_catalog"));
            } else if lower == "sqlite_sequence" {
                let previous = (0..index)
                    .rev()
                    .find(|&position| tokens[position].kind != TokenKind::Trivia);
                if let Some(dot) = previous.filter(|&position| tokens[position].value == ".") {
                    let schema = (0..dot)
                        .rev()
                        .find(|&position| tokens[position].kind != TokenKind::Trivia);
                    if let Some(schema) = schema {
                        if tokens[schema].kind == TokenKind::Identifier
                            && matches!(
                                tokens[schema].value.to_ascii_lowercase().as_str(),
                                "main" | "temp"
                            )
                        {
                            tokens[schema].raw = "temp".to_string();
                            tokens[index].raw = Self::quote("tb_logical_sequence");
                            continue;
                        }
                    }
                }
                tokens[index].raw = format!("temp.{}", Self::quote("tb_logical_sequence"));
            } else if self.object_names.contains(&lower) {
                if self.temporary_object_names.contains(&lower)
                    && (self.temporary_namespace_enabled || is_temp_qualified(&tokens, index))
                {
                    continue;
                }
                tokens[index].raw = Self::quote(&self.physical(&value));
            }
        }
        Ok(tokens.into_iter().map(|token| token.raw).collect())
    }

    fn register_statement(&mut self, tokens: &[Token], significant: &[usize]) {
        let word = |position: usize| {
            significant
                .get(position)
                .map(|&index| tokens[index].value.to_ascii_uppercase())
                .unwrap_or_default()
        };
        let mut position;
        let mut temporary_table = false;
        match word(0).as_str() {
            "CREATE" => {
                let temporary = matches!(word(1).as_str(), "TEMP" | "TEMPORARY");
                position = 1;
                while ["TEMP", "TEMPORARY", "UNIQUE", "VIRTUAL"].contains(&word(position).as_str())
                {
                    position += 1;
                }
                if !["TABLE", "INDEX", "VIEW", "TRIGGER"].contains(&word(position).as_str()) {
                    return;
                }
                temporary_table = temporary && word(position) == "TABLE";
                position += 1;
            }
            "DROP" => {
                position = 1;
                if !["TABLE", "INDEX", "VIEW", "TRIGGER"].contains(&word(position).as_str()) {
                    return;
                }
                position += 1;
            }
            "ALTER" if word(1) == "TABLE" => {
                if let Some(name) = object_name(tokens, significant, 2) {
                    self.object_names.insert(name.to_ascii_lowercase());
                }
                for position in 2..significant.len().saturating_sub(2) {
                    if word(position) == "RENAME" && word(position + 1) == "TO" {
                        if let Some(name) = object_name(tokens, significant, position + 2) {
                            self.object_names.insert(name.to_ascii_lowercase());
                        }
                    }
                }
                return;
            }
            _ => return,
        }
        if word(position) == "IF" {
            position += 1;
            if word(position) == "NOT" {
                position += 1;
            }
            if word(position) == "EXISTS" {
                position += 1;
            }
        }
        if let Some(name) = object_name(tokens, significant, position) {
            let name = name.to_ascii_lowercase();
            self.object_names.insert(name.clone());
            // Only the producer's explicit TEMP namespace uses unprefixed
            // names. Ordinary comparison TEMP tables retain the module prefix
            // in both their declaration and subsequent temp-qualified reads.
            if temporary_table && self.temporary_namespace_enabled {
                self.temporary_object_names.insert(name);
            }
        }
    }

    /// Convert stored physical DDL/catalog SQL back to logical identifiers.
    pub(crate) fn unbind(&self, sql: &str) -> Result<String, BindingError> {
        let tokens = tokenize(sql)?;
        let mut output = String::new();
        for token in tokens {
            if token.kind == TokenKind::Identifier {
                if let Some(suffix) = token.value.strip_prefix("sqlite_autoindex_") {
                    if let Some(logical) = suffix.strip_prefix(&self.prefix) {
                        output.push_str(&Self::quote(&format!("sqlite_autoindex_{logical}")));
                        continue;
                    }
                }
                if let Some(logical) = token.value.strip_prefix(&self.prefix) {
                    output.push_str(&Self::quote(logical));
                    continue;
                }
                if token.value == "tb_logical_catalog" {
                    output.push_str(&Self::quote("sqlite_master"));
                    continue;
                }
            }
            output.push_str(&token.raw);
        }
        Ok(output)
    }
}

fn object_name(tokens: &[Token], significant: &[usize], position: usize) -> Option<String> {
    let mut index = *significant.get(position)?;
    if tokens[index].kind != TokenKind::Identifier {
        return None;
    }
    if significant
        .get(position + 1)
        .is_some_and(|&dot| tokens[dot].value == ".")
    {
        index = *significant.get(position + 2)?;
        if tokens[index].kind != TokenKind::Identifier {
            return None;
        }
    }
    Some(tokens[index].value.clone())
}

fn is_temp_qualified(tokens: &[Token], index: usize) -> bool {
    let previous = (0..index)
        .rev()
        .find(|&position| tokens[position].kind != TokenKind::Trivia);
    let Some(dot) = previous.filter(|&position| tokens[position].value == ".") else {
        return false;
    };
    let schema = (0..dot)
        .rev()
        .find(|&position| tokens[position].kind != TokenKind::Trivia);
    schema.is_some_and(|position| {
        tokens[position].kind == TokenKind::Identifier
            && tokens[position].value.eq_ignore_ascii_case("temp")
    })
}

fn bind_pragma_table_argument(
    tokens: &mut [Token],
    significant: &[usize],
    object_names: &HashSet<String>,
    temporary_object_names: &HashSet<String>,
    temporary_namespace_enabled: bool,
    prefix: &str,
) {
    let Some(&first) = significant.first() else {
        return;
    };
    let first_word = tokens[first].value.to_ascii_lowercase();
    let (pragma_name, name_position) = if first_word == "pragma" {
        let mut position = 1;
        if significant
            .get(position + 1)
            .is_some_and(|&index| tokens[index].value == ".")
        {
            position += 2;
        }
        let name = significant
            .get(position)
            .map(|&index| tokens[index].value.to_ascii_lowercase())
            .unwrap_or_default();
        (name, position)
    } else {
        let Some((position, name)) =
            significant
                .iter()
                .enumerate()
                .find_map(|(position, &index)| {
                    tokens[index]
                        .value
                        .to_ascii_lowercase()
                        .strip_prefix("pragma_")
                        .map(|name| (position, name.to_string()))
                })
        else {
            return;
        };
        (name, position)
    };
    if !matches!(
        pragma_name.as_str(),
        "table_info"
            | "table_xinfo"
            | "foreign_key_list"
            | "foreign_key_check"
            | "index_list"
            | "index_info"
            | "index_xinfo"
    ) {
        return;
    }
    let Some(open_position) = significant
        .iter()
        .enumerate()
        .skip(name_position + 1)
        .find_map(|(position, &index)| (tokens[index].value == "(").then_some(position))
    else {
        return;
    };
    let Some(&argument_index) = significant.get(open_position + 1) else {
        return;
    };
    if tokens[argument_index].kind != TokenKind::String {
        return;
    }
    let logical = tokens[argument_index].value.to_ascii_lowercase();
    let temp_schema = first_word == "pragma"
        && significant
            .get(1)
            .is_some_and(|&index| tokens[index].value.eq_ignore_ascii_case("temp"))
        && significant
            .get(2)
            .is_some_and(|&index| tokens[index].value == ".");
    if temporary_object_names.contains(&logical) && (temporary_namespace_enabled || temp_schema) {
        return;
    }
    if !object_names.contains(&logical) {
        return;
    }
    let physical = format!("{prefix}{}", tokens[argument_index].value);
    tokens[argument_index].raw = format!("'{}'", physical.replace('\'', "''"));
    tokens[argument_index].value = physical;
}

fn split_complete_statements(sql: &str) -> Result<Vec<&str>, BindingError> {
    let mut statements = Vec::new();
    let mut start = 0usize;
    for (index, character) in sql.char_indices() {
        if character != ';' {
            continue;
        }
        let end = index + character.len_utf8();
        let candidate = &sql[start..end];
        let c_sql = CString::new(candidate).map_err(|_| BindingError::MalformedSql)?;
        // sqlite3_complete understands trigger bodies and quoted semicolons.
        if unsafe { rusqlite::ffi::sqlite3_complete(c_sql.as_ptr()) } != 0 {
            statements.push(candidate);
            start = end;
        }
    }
    if start < sql.len() {
        statements.push(&sql[start..]);
    }
    if statements.is_empty() {
        statements.push(sql);
    }
    Ok(statements)
}

fn tokenize(sql: &str) -> Result<Vec<Token>, BindingError> {
    let bytes = sql.as_bytes();
    let mut tokens = Vec::new();
    let mut cursor = 0;
    while cursor < bytes.len() {
        let start = cursor;
        let byte = bytes[cursor];
        if byte.is_ascii_whitespace() {
            cursor += 1;
            while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                cursor += 1;
            }
            tokens.push(token(TokenKind::Trivia, sql, start, cursor, String::new()));
            continue;
        }
        if byte == b'-' && bytes.get(cursor + 1) == Some(&b'-') {
            cursor += 2;
            while cursor < bytes.len() && bytes[cursor] != b'\n' {
                cursor += 1;
            }
            tokens.push(token(TokenKind::Trivia, sql, start, cursor, String::new()));
            continue;
        }
        if byte == b'/' && bytes.get(cursor + 1) == Some(&b'*') {
            cursor += 2;
            while cursor + 1 < bytes.len() && !(bytes[cursor] == b'*' && bytes[cursor + 1] == b'/')
            {
                cursor += 1;
            }
            if cursor + 1 >= bytes.len() {
                return Err(BindingError::MalformedSql);
            }
            cursor += 2;
            tokens.push(token(TokenKind::Trivia, sql, start, cursor, String::new()));
            continue;
        }
        if matches!(byte, b'\'' | b'"' | b'`' | b'[') {
            let identifier = byte != b'\'';
            let end = if byte == b'[' { b']' } else { byte };
            cursor += 1;
            let mut value = Vec::new();
            let mut closed = false;
            while cursor < bytes.len() {
                if bytes[cursor] == end {
                    cursor += 1;
                    if byte != b'[' && bytes.get(cursor) == Some(&end) {
                        value.push(end);
                        cursor += 1;
                    } else {
                        closed = true;
                        break;
                    }
                } else {
                    value.push(bytes[cursor]);
                    cursor += 1;
                }
            }
            if !closed {
                return Err(BindingError::MalformedSql);
            }
            let kind = if identifier {
                TokenKind::Identifier
            } else {
                TokenKind::String
            };
            let value = String::from_utf8_lossy(&value).into_owned();
            tokens.push(token(kind, sql, start, cursor, value));
            continue;
        }
        if matches!(byte, b'?' | b':' | b'@' | b'$') {
            cursor += 1;
            if byte == b'?' {
                while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
                    cursor += 1;
                }
            } else if cursor < bytes.len() && is_identifier_continue(bytes[cursor]) {
                while cursor < bytes.len() && is_identifier_continue(bytes[cursor]) {
                    cursor += 1;
                }
                if byte == b'$' {
                    while bytes.get(cursor..cursor + 2) == Some(b"::") {
                        cursor += 2;
                        while cursor < bytes.len() && is_identifier_continue(bytes[cursor]) {
                            cursor += 1;
                        }
                    }
                    if bytes.get(cursor) == Some(&b'(') {
                        cursor += 1;
                        while cursor < bytes.len() && bytes[cursor] != b')' {
                            cursor += 1;
                        }
                        if cursor < bytes.len() {
                            cursor += 1;
                        }
                    }
                }
            }
            tokens.push(token(
                TokenKind::Parameter,
                sql,
                start,
                cursor,
                String::new(),
            ));
            continue;
        }
        if is_identifier_start(byte) {
            cursor += 1;
            while cursor < bytes.len() && is_identifier_continue(bytes[cursor]) {
                cursor += 1;
            }
            let raw = &sql[start..cursor];
            tokens.push(token(
                TokenKind::Identifier,
                sql,
                start,
                cursor,
                raw.to_string(),
            ));
            continue;
        }
        cursor += 1;
        tokens.push(token(
            TokenKind::Punctuation,
            sql,
            start,
            cursor,
            sql[start..cursor].to_string(),
        ));
    }
    Ok(tokens)
}

fn token(kind: TokenKind, sql: &str, start: usize, end: usize, value: String) -> Token {
    Token {
        kind,
        raw: sql[start..end].to_string(),
        value,
    }
}

fn is_identifier_start(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphabetic() || byte >= 0x80
}

fn is_identifier_continue(byte: u8) -> bool {
    is_identifier_start(byte) || byte.is_ascii_digit() || byte == b'$'
}

#[cfg(test)]
mod tests {
    use super::*;

    fn namespace() -> SQLiteStoreNamespace {
        SQLiteStoreNamespace::new("s123_", ["events".to_string(), "idx_events".to_string()])
    }

    #[test]
    fn binds_only_identifiers_and_preserves_values_comments_and_parameters() {
        let mut ns = namespace();
        let sql = "CREATE TABLE IF NOT EXISTS events (payload TEXT, note TEXT DEFAULT 'events', v TEXT); -- events\nINSERT INTO events VALUES (:events, @events, $events, ?1); /* events */";
        let bound = ns.bind(sql).unwrap();
        assert!(bound.contains("CREATE TABLE IF NOT EXISTS \"s123_events\""));
        assert!(bound.contains("(payload TEXT, note TEXT DEFAULT 'events'"));
        assert!(bound.contains("-- events\nINSERT INTO \"s123_events\""));
        assert!(bound.contains(":events, @events, $events, ?1"));
        assert!(bound.ends_with("/* events */"));
        let unbound = ns.unbind(&bound).unwrap();
        assert!(unbound.contains("DEFAULT 'events'"));
        assert!(unbound.contains(":events, @events, $events, ?1"));
        assert!(unbound.contains("-- events\nINSERT INTO \"events\""));
    }

    #[test]
    fn discovers_new_and_renamed_objects_and_rewrites_catalog_identifiers() {
        let mut ns = SQLiteStoreNamespace::new("sx_", std::iter::empty());
        let bound = ns.bind("ALTER TABLE old_name RENAME TO new_name").unwrap();
        assert!(bound.contains("\"sx_old_name\""));
        assert!(bound.contains("\"sx_new_name\""));
        assert_eq!(
            ns.bind("SELECT name FROM sqlite_master WHERE name='old_name'")
                .unwrap(),
            "SELECT name FROM temp.\"tb_logical_catalog\" WHERE name='old_name'"
        );
    }

    #[test]
    fn quoted_identifiers_are_bound_and_escaped() {
        let mut ns = SQLiteStoreNamespace::new("sx_", std::iter::empty());
        assert_eq!(
            ns.bind("CREATE TABLE [odd name] (`x` TEXT)").unwrap(),
            "CREATE TABLE \"sx_odd name\" (`x` TEXT)"
        );
        let mut escaped = SQLiteStoreNamespace::new("sx_", ["a\"b".to_string()]);
        assert_eq!(
            escaped.bind("SELECT \"a\"\"b\" FROM \"a\"\"b\"").unwrap(),
            "SELECT \"sx_a\"\"b\" FROM \"sx_a\"\"b\""
        );
    }

    #[test]
    fn canonical_sql_normalizes_identifiers_and_trivia_but_keeps_literals() {
        let first = SQLiteStoreNamespace::canonical_sql(
            "CREATE TABLE `Events` (\"Value\" TEXT DEFAULT 'Keep  Case'); -- note\n",
        )
        .unwrap();
        let second = SQLiteStoreNamespace::canonical_sql(
            "create /* note */ table [events]([value] text default 'Keep  Case');",
        )
        .unwrap();
        assert_eq!(first, second);
        assert_ne!(
            first,
            SQLiteStoreNamespace::canonical_sql(
                "create table events(value text default 'keep  case')"
            )
            .unwrap()
        );
    }

    #[test]
    fn detects_without_rowid_only_from_unquoted_keywords() {
        assert!(SQLiteStoreNamespace::is_without_rowid(
            "CREATE TABLE t(k TEXT PRIMARY KEY) WITHOUT ROWID"
        )
        .unwrap());
        assert!(!SQLiteStoreNamespace::is_without_rowid(
            "CREATE TABLE t(\"WITHOUT\" TEXT, \"ROWID\" TEXT)"
        )
        .unwrap());
    }

    #[test]
    fn rejects_unterminated_literals_and_comments() {
        assert_eq!(tokenize("SELECT 'oops"), Err(BindingError::MalformedSql));
        assert_eq!(
            tokenize("SELECT 1 /* oops"),
            Err(BindingError::MalformedSql)
        );
    }

    #[test]
    fn module_user_version_is_rewritten_to_container_metadata() {
        let store_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let prefix = format!("s{store_id}_");
        let mut binding = StoreSqlBinding::new(store_id, prefix, Vec::new()).unwrap();
        assert_eq!(
            binding.sql("PRAGMA user_version").unwrap(),
            format!("SELECT user_version FROM main.tb_stores WHERE store_id='{store_id}'")
        );
        assert_eq!(
            binding.sql("PRAGMA user_version=17").unwrap(),
            format!("UPDATE main.tb_stores SET user_version=17 WHERE store_id='{store_id}'")
        );
        assert_eq!(
            binding.sql("PRAGMA user_version=-1"),
            Err(BindingError::InvalidUserVersion)
        );
    }

    #[test]
    fn batch_binding_keeps_later_statements_and_trigger_bodies_intact() {
        let store_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let prefix = format!("s{store_id}_");
        let mut binding = StoreSqlBinding::new(store_id, prefix.clone(), Vec::new()).unwrap();
        let sql = "PRAGMA user_version=17; CREATE TABLE events(id INTEGER PRIMARY KEY, value TEXT); CREATE TRIGGER event_change AFTER INSERT ON events BEGIN UPDATE events SET value='x;y' WHERE id=NEW.id; END;";
        let bound = binding.sql(sql).unwrap();
        assert!(bound.starts_with(&format!(
            "UPDATE main.tb_stores SET user_version=17 WHERE store_id='{store_id}';"
        )));
        assert!(bound.contains(&format!("CREATE TABLE \"{prefix}events\"")));
        assert!(bound.contains(&format!("CREATE TRIGGER \"{prefix}event_change\"")));
        assert!(bound.contains(&format!("UPDATE \"{prefix}events\" SET value='x;y'")));
        assert!(!bound.contains("PRAGMA user_version"));
    }

    #[test]
    fn pragma_table_arguments_and_catalog_qualifiers_are_store_scoped() {
        let store_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let prefix = format!("s{store_id}_");
        let mut binding =
            StoreSqlBinding::new(store_id, prefix.clone(), ["events".into()]).unwrap();
        assert_eq!(
            binding.sql("PRAGMA main.table_info('events')").unwrap(),
            format!("PRAGMA main.table_info('{prefix}events')")
        );
        assert_eq!(
            binding
                .sql("SELECT name FROM pragma_table_info('events')")
                .unwrap(),
            format!("SELECT name FROM pragma_table_info('{prefix}events')")
        );
        assert_eq!(
            binding.sql("SELECT name FROM main.sqlite_master").unwrap(),
            "SELECT name FROM temp.\"tb_logical_catalog\""
        );
        assert_eq!(
            binding.sql("PRAGMA foreign_key_check").unwrap(),
            format!(
                "SELECT * FROM pragma_foreign_key_check WHERE substr(\"table\",1,{})='{prefix}'",
                prefix.len()
            )
        );
    }

    #[test]
    fn attached_stage_alias_is_rewritten_into_main_and_is_read_only() {
        let store_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let prefix = format!("s{store_id}_");
        let mut binding =
            StoreSqlBinding::new(store_id, prefix.clone(), ["events".into()]).unwrap();
        binding.register_attached_namespace(
            "exact_stage_import",
            "saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_".into(),
            ["events".into(), "manifest".into()],
        );
        assert_eq!(
            binding.sql("SELECT * FROM exact_stage_import.events").unwrap(),
            "SELECT * FROM main.\"saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_events\""
        );
        assert!(binding
            .sql("SELECT 'exact_stage_import.events' FROM events")
            .unwrap()
            .contains("'exact_stage_import.events'"));
        assert_eq!(
            binding.sql("DELETE FROM exact_stage_import.events"),
            Err(BindingError::ReadOnlyAttachedStore)
        );
        assert!(binding.sql("INSERT INTO events SELECT * FROM exact_stage_import.events").unwrap()
            .contains("FROM main.\"saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_events\""));
        assert_eq!(binding.sql("PRAGMA exact_stage_import.table_info(events)").unwrap(),
            "PRAGMA main.table_info(\"saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_events\")");
    }

    #[test]
    fn module_vacuum_never_rebuilds_the_shared_container() {
        let store_id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let mut binding =
            StoreSqlBinding::new(store_id, format!("s{store_id}_"), Vec::new()).unwrap();
        assert_eq!(
            binding.sql("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"),
            Ok("SELECT 0 AS busy,0 AS log,0 AS checkpointed".into())
        );
        assert_eq!(binding.sql("VACUUM;"), Ok(String::new()));
        assert_eq!(
            binding.sql("VACUUM INTO 'copy.sqlite'"),
            Err(BindingError::WholeContainerVacuum)
        );
    }
}
