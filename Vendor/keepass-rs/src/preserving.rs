//! SSH Hub's bounded XML-preserving KDBX4.0/4.1 editor. No plaintext file export.
//! Unknown XML elements, attributes, field protection, attachment IDs and order survive edits.
#![allow(missing_docs)]
use crate::{
    config::{DatabaseConfig, DatabaseVersion, VariantDictionary},
    crypt::ciphers::Cipher,
    db::{DatabaseSaveError, Value},
    DatabaseKey,
};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use quick_xml::{
    events::{BytesEnd, BytesStart, BytesText, Event},
    Reader, Writer,
};
use std::convert::TryInto;
use zeroize::Zeroizing;

#[derive(Clone, PartialEq)]
pub enum Item {
    Node(Node),
    Text(Zeroizing<String>),
    Comment(String),
    PI(String),
}
#[derive(Clone, PartialEq)]
pub struct Node {
    pub name: String,
    pub attrs: Vec<(String, String)>,
    pub items: Vec<Item>,
    secret: Option<Zeroizing<Vec<u8>>>,
}
impl Node {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.into(),
            attrs: vec![],
            items: vec![],
            secret: None,
        }
    }
    pub fn children(&self) -> impl Iterator<Item = &Node> {
        self.items
            .iter()
            .filter_map(|x| if let Item::Node(n) = x { Some(n) } else { None })
    }
    pub fn children_mut(&mut self) -> impl Iterator<Item = &mut Node> {
        self.items
            .iter_mut()
            .filter_map(|x| if let Item::Node(n) = x { Some(n) } else { None })
    }
    pub fn child(&self, name: &str) -> Option<&Node> {
        self.children().find(|n| n.name == name)
    }
    pub fn child_mut(&mut self, name: &str) -> Option<&mut Node> {
        self.children_mut().find(|n| n.name == name)
    }
    pub fn ensure(&mut self, name: &str) -> &mut Node {
        if !self.children().any(|n| n.name == name) {
            self.items.push(Item::Node(Node::new(name)));
        }
        self.child_mut(name).expect("just inserted")
    }
    pub fn text(&self) -> String {
        if let Some(bytes) = &self.secret {
            return String::from_utf8_lossy(bytes).into_owned();
        }
        self.items
            .iter()
            .filter_map(|i| {
                if let Item::Text(t) = i {
                    Some(t.as_str())
                } else {
                    None
                }
            })
            .collect()
    }
    pub fn set_text(&mut self, text: &str, protect: bool) {
        self.items.clear();
        self.secret = None;
        self.attrs.retain(|(k, _)| k != "Protected");
        if protect {
            self.attrs.push(("Protected".into(), "True".into()));
            self.secret = Some(Zeroizing::new(text.as_bytes().to_vec()));
        } else if !text.is_empty() {
            self.items.push(Item::Text(Zeroizing::new(text.into())));
        }
    }
    pub fn normalize(&mut self) {
        let items = std::mem::take(&mut self.items);
        for item in items {
            match item {
                Item::Text(t) => text(self, &t),
                Item::Node(mut n) => {
                    n.normalize();
                    self.items.push(Item::Node(n));
                }
                other => self.items.push(other),
            }
        }
    }
    fn unprotect(&mut self, cipher: &mut dyn Cipher) -> Result<(), &'static str> {
        if self
            .attrs
            .iter()
            .any(|(k, v)| k == "Protected" && v == "True")
        {
            if self.children().next().is_some() {
                return Err("unsupported_xml");
            }
            let encoded = Zeroizing::new(self.text());
            let bytes = B64
                .decode(encoded.as_bytes())
                .map_err(|_| "unsupported_xml")?;
            self.secret = Some(Zeroizing::new(
                cipher.decrypt(&bytes).map_err(|_| "unsupported_xml")?,
            ));
            self.items.clear();
        } else {
            for n in self.children_mut() {
                n.unprotect(cipher)?;
            }
        }
        Ok(())
    }
    fn write(
        &self,
        w: &mut Writer<Vec<u8>>,
        cipher: &mut dyn Cipher,
    ) -> Result<(), DatabaseSaveError> {
        let mut start = BytesStart::new(&self.name);
        for (k, v) in &self.attrs {
            start.push_attribute((k.as_str(), v.as_str()));
        }
        w.write_event(Event::Start(start))?;
        if let Some(secret) = &self.secret {
            let encrypted = cipher.encrypt(secret)?;
            let encoded = B64.encode(&encrypted);
            w.write_event(Event::Text(BytesText::new(&encoded)))?;
        } else {
            for i in &self.items {
                match i {
                    Item::Node(n) => n.write(w, cipher)?,
                    Item::Text(t) => w.write_event(Event::Text(BytesText::new(t)))?,
                    Item::Comment(t) => {
                        w.write_event(Event::Comment(BytesText::from_escaped(t)))?
                    }
                    Item::PI(t) => w.write_event(Event::PI(quick_xml::events::BytesPI::new(t)))?,
                }
            }
        }
        w.write_event(Event::End(BytesEnd::new(&self.name)))?;
        Ok(())
    }
}
pub struct Document {
    pub root: Node,
    config: DatabaseConfig,
    attachments: Vec<Value<Vec<u8>>>,
    comments: Vec<Vec<u8>>,
    kdf: Option<VariantDictionary>,
}
impl Document {
    pub fn open(data: &[u8], key: &DatabaseKey) -> Result<Self, &'static str> {
        let (config, attachments, mut cipher, xml) =
            crate::format::kdbx4::decrypt_kdbx4(data, key).map_err(|_| "credentials_or_corrupt")?;
        let xml = Zeroizing::new(xml);
        if !matches!(config.version, DatabaseVersion::KDB4(0 | 1)) {
            return Err("read_only_format");
        }
        let mut root = parse(&xml)?;
        if root.name != "KeePassFile" {
            return Err("unsupported_xml");
        }
        root.unprotect(&mut *cipher)?;
        fn unique(
            n: &Node,
            ids: &mut std::collections::HashSet<uuid::Uuid>,
        ) -> Result<(), &'static str> {
            if n.name == "History" {
                return Ok(());
            }
            if n.name == "Entry" || n.name == "Group" {
                if n.children().filter(|n| n.name == "UUID").count() != 1 {
                    return Err("unsupported_xml");
                }
                let id = n
                    .child("UUID")
                    .and_then(|n| uuid_from_text(&n.text()))
                    .ok_or("unsupported_xml")?;
                if !ids.insert(id) {
                    return Err("unsupported_xml");
                }
            }
            if n.name == "Entry" {
                let mut keys = std::collections::HashSet::new();
                for field in n.children().filter(|n| n.name == "String") {
                    if field.children().filter(|n| n.name == "Key").count() != 1
                        || field.children().filter(|n| n.name == "Value").count() != 1
                        || !keys.insert(field.child("Key").map(Node::text))
                    {
                        return Err("unsupported_xml");
                    }
                }
            }
            for child in n.children() {
                unique(child, ids)?;
            }
            Ok(())
        }
        unique(&root, &mut std::collections::HashSet::new())?;
        // Keep header comments and all KDF parameters, including vendor extensions.
        let mut comments = vec![];
        let mut kdf = None;
        let mut pos = 12;
        let mut seen = std::collections::HashSet::new();
        loop {
            let kind = *data.get(pos).ok_or("unsupported_xml")?;
            let length = u32::from_le_bytes(
                data.get(pos + 1..pos + 5)
                    .ok_or("unsupported_xml")?
                    .try_into()
                    .map_err(|_| "unsupported_xml")?,
            ) as usize;
            let bytes = data
                .get(pos + 5..pos + 5 + length)
                .ok_or("unsupported_xml")?;
            pos += 5 + length;
            if kind == 0 {
                break;
            }
            if kind == 1 {
                comments.push(bytes.to_vec());
            } else if !seen.insert(kind) {
                return Err("unsupported_xml");
            }
            if kind == 11 {
                kdf = Some(VariantDictionary::parse(bytes).map_err(|_| "unsupported_xml")?);
            }
        }
        Ok(Self {
            root,
            config,
            attachments,
            comments,
            kdf,
        })
    }
    pub fn supports_previous_parent(&self) -> bool {
        self.config.version == DatabaseVersion::KDB4(1)
    }
    pub fn save(&self, key: &DatabaseKey) -> Result<Vec<u8>, &'static str> {
        let mut output = Vec::new();
        crate::format::kdbx4::dump::dump_kdbx4_payload(
            &self.config,
            key,
            &mut output,
            &self.comments,
            self.kdf.as_ref(),
            |cipher| {
                let mut w = Writer::new(Vec::new());
                self.root.write(&mut w, cipher)?;
                Ok((w.into_inner(), self.attachments.clone()))
            },
        )
        .map_err(|_| "write_failed")?;
        if output.len() > 64 * 1024 * 1024 {
            return Err("file_limit");
        }
        // Independently decrypt the output and compare the entire XML tree and attachments.
        let check = Self::open(&output, key)?;
        if check.root != self.root
            || check.attachments != self.attachments
            || check.config != self.config
        {
            return Err("verification_failed");
        }
        if check.comments != self.comments {
            return Err("verification_failed");
        }
        Ok(output)
    }
}
fn parse(xml: &[u8]) -> Result<Node, &'static str> {
    let mut r = Reader::from_reader(xml);
    let mut stack: Vec<Node> = vec![];
    let mut root = None;
    let mut count = 0;
    loop {
        count += 1;
        if count > 500_000 || stack.len() > 128 {
            return Err("unsupported_xml");
        }
        let event = r.read_event().map_err(|_| "unsupported_xml")?;
        match event {
            Event::Start(ref start) | Event::Empty(ref start) => {
                let mut n = Node::new(start.name().as_ref());
                for a in start.attributes() {
                    let a = a.map_err(|_| "unsupported_xml")?;
                    n.attrs.push((
                        a.key.as_ref().into(),
                        a.normalized_value(quick_xml::XmlVersion::Implicit1_0)
                            .map_err(|_| "unsupported_xml")?
                            .into_owned(),
                    ));
                }
                if matches!(event, Event::Empty(_)) {
                    append(n, &mut stack, &mut root)?;
                } else {
                    stack.push(n);
                }
            }
            Event::End(_) => {
                let n = stack.pop().ok_or("unsupported_xml")?;
                append(n, &mut stack, &mut root)?;
            }
            Event::Text(t) => {
                let t = t.xml10_content();
                if let Some(n) = stack.last_mut() {
                    text(n, &t);
                } else if !t.trim().is_empty() {
                    return Err("unsupported_xml");
                }
            }
            Event::CData(t) => {
                text(
                    stack.last_mut().ok_or("unsupported_xml")?,
                    &t.xml10_content(),
                );
            }
            Event::GeneralRef(t) => {
                let s = if let Some(c) = t.resolve_char_ref().map_err(|_| "unsupported_xml")? {
                    c.to_string()
                } else {
                    match t.as_ref() {
                        "amp" => "&",
                        "lt" => "<",
                        "gt" => ">",
                        "quot" => "\"",
                        "apos" => "'",
                        _ => return Err("unsupported_xml"),
                    }
                    .into()
                };
                text(stack.last_mut().ok_or("unsupported_xml")?, &s);
            }
            Event::Comment(t) => {
                if let Some(n) = stack.last_mut() {
                    n.items.push(Item::Comment(t.xml10_content().into_owned()));
                }
            }
            Event::PI(t) => {
                if let Some(n) = stack.last_mut() {
                    n.items.push(Item::PI(t.as_ref().into()));
                }
            }
            Event::Decl(_) => {}
            Event::Eof => break,
            _ => return Err("unsupported_xml"), // no DTD or external/custom entities
        }
    }
    if !stack.is_empty() {
        return Err("unsupported_xml");
    }
    root.ok_or("unsupported_xml")
}
fn text(n: &mut Node, t: &str) {
    if t.is_empty() {
        return;
    }
    if let Some(Item::Text(last)) = n.items.last_mut() {
        last.push_str(t);
    } else {
        n.items.push(Item::Text(Zeroizing::new(t.into())));
    }
}
fn append(n: Node, stack: &mut [Node], root: &mut Option<Node>) -> Result<(), &'static str> {
    if let Some(p) = stack.last_mut() {
        p.items.push(Item::Node(n));
    } else if root.is_none() {
        *root = Some(n);
    } else {
        return Err("unsupported_xml");
    }
    Ok(())
}

pub fn uuid_from_text(text: &str) -> Option<uuid::Uuid> {
    B64.decode(text)
        .ok()
        .and_then(|b| uuid::Uuid::from_slice(&b).ok())
}
pub fn uuid_text(id: uuid::Uuid) -> String {
    B64.encode(id.as_bytes())
}
pub fn timestamp_now() -> String {
    let seconds = chrono::Utc::now().timestamp() + 62_135_596_800;
    B64.encode(seconds.to_le_bytes())
}
