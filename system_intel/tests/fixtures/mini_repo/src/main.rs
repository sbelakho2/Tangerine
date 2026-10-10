fn main() -> i32 {
    let widget = crate::lib::build("x".to_string());
    if widget.name.len() > 0 { 0 } else { 1 }
}
