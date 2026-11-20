use icu_segmenter::LineSegmenter;
use krilla::Data;
use krilla::Document;
use krilla::geom::{PathBuilder, Point, Rect};
use krilla::page::PageSettings;
use krilla::paint::Stroke;
use krilla::text::{Font, TextDirection};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct PdfSpikeModel {
    pub pages: Vec<PdfSpikePage>,
}

#[derive(Debug, Deserialize)]
pub struct PdfSpikePage {
    pub width: f32,
    pub height: f32,
    pub runs: Vec<PdfSpikeTextRun>,
    #[serde(default)]
    pub strokes: Vec<Vec<[f32; 2]>>,
}

#[derive(Debug, Deserialize)]
pub struct PdfSpikeTextRun {
    pub text: String,
    pub x: f32,
    pub y: f32,
    pub max_width: f32,
    pub font_size: f32,
    pub line_height: f32,
}

/// Breaks [text] into lines at ICU/UAX#14 word/line boundaries (supporting Thai without spaces)
/// so no word is cut in the middle when fitting within [max_width].
pub fn break_lines_thai_safe(text: &str, max_width: f32, approx_char_width: f32) -> Vec<String> {
    let segmenter = LineSegmenter::new_auto(Default::default());
    let mut lines = Vec::new();
    for para in text.split('\n') {
        let breaks: Vec<usize> = segmenter.segment_str(para).collect();
        let mut current = String::new();
        let mut prev = 0usize;
        for &b in &breaks {
            if b <= prev {
                continue;
            }
            let seg = &para[prev..b];
            let next_w = (current.chars().count() + seg.chars().count()) as f32 * approx_char_width;
            if !current.is_empty() && next_w > max_width {
                lines.push(current.trim_end().to_string());
                current = seg.to_string();
            } else {
                current.push_str(seg);
            }
            prev = b;
        }
        if !current.is_empty() || para.is_empty() {
            lines.push(current.trim_end().to_string());
        }
    }
    lines
}

/// Renders a [PdfSpikeModel] using krilla (OpenType shaping + font embedding + vector strokes).
pub fn render_pdf_bytes(model: &PdfSpikeModel, thai_font_bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    let font = Font::new(Data::from(thai_font_bytes), 0)
        .ok_or_else(|| "failed to load TTF font".to_string())?;
    let mut doc = Document::new();
    for page_in in &model.pages {
        let mut page = doc.start_page_with(PageSettings::from_wh(page_in.width, page_in.height)
            .ok_or_else(|| "invalid page size".to_string())?);
        let mut surface = page.surface();

        for stroke in &page_in.strokes {
            if stroke.len() < 2 {
                continue;
            }
            let mut pb = PathBuilder::new();
            pb.move_to(stroke[0][0], stroke[0][1]);
            for pt in &stroke[1..] {
                pb.line_to(pt[0], pt[1]);
            }
            if let Some(path) = pb.finish() {
                surface.set_stroke(Some(Stroke {
                    width: 1.5,
                    ..Default::default()
                }));
                surface.draw_path(&path);
            }
        }

        for run in &page_in.runs {
            let approx_cw = run.font_size * 0.52;
            let lines = break_lines_thai_safe(&run.text, run.max_width, approx_cw);
            for (idx, line) in lines.iter().enumerate() {
                let y = run.y + (idx as f32) * run.line_height;
                surface.draw_text(
                    Point::from_xy(run.x, y),
                    font.clone(),
                    run.font_size,
                    line,
                    false,
                    TextDirection::Auto,
                );
            }
        }
        surface.finish();
        page.finish();
    }
    let _ = Rect::from_xywh(0.0, 0.0, 1.0, 1.0);
    doc.finish().map_err(|e| format!("krilla finish error: {e:?}"))
}

/// C-ABI entry point for Flutter FFI. Returns bytes written (or negative on error).
#[unsafe(no_mangle)]
pub extern "C" fn asodya_krilla_spike_ping() -> i32 {
    41
}
