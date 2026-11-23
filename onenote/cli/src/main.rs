// onenote-html <Eingabe.one|.onetoc2> <Ausgabeordner>
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 { eprintln!("Nutzung: onenote-html <Datei.one> <Ausgabeordner>"); std::process::exit(2); }
    let input = std::fs::canonicalize(&a[1]).expect("Eingabe fehlt");
    let base = input.parent().unwrap().to_string_lossy().to_string();
    if let Err(e) = renderer::convert(&input.to_string_lossy(), &a[2], &base) {
        eprintln!("Fehler: {e:?}"); std::process::exit(1);
    }
}
