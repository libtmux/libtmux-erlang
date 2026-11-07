use regex::bytes::{Regex, RegexBuilder};
use std::collections::HashMap;
use std::io::{self, BufRead};

fn main() {
    let mut compiled: HashMap<String, Regex> = HashMap::new();
    for line in io::stdin().lock().lines() {
        let line = line.expect("fixture input");
        let (pattern, hex) = line.split_once('\t').expect("pattern and hex subject");
        let subject: Vec<u8> = hex
            .as_bytes()
            .chunks_exact(2)
            .map(|b| u8::from_str_radix(std::str::from_utf8(b).unwrap(), 16).unwrap())
            .collect();
        if !subject.is_ascii() {
            println!("unsupported_regex_subject");
            continue;
        }
        let regex = compiled.entry(pattern.to_owned()).or_insert_with(|| {
            RegexBuilder::new(pattern)
                .unicode(false)
                .size_limit(1 << 20)
                .dfa_size_limit(1 << 20)
                .build()
                .expect("validated portable pattern")
        });
        println!("{}", regex.is_match(&subject));
    }
}
