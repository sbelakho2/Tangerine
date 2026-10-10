use crate::core::Thing;

pub struct Widget {
    pub name: String,
}

pub trait Render {
    fn render(&self) -> String;
}

pub fn build(name: String) -> Widget {
    Widget { name }
}
