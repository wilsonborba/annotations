use icu_segmenter::LineSegmenter;
use krilla::Data;
use krilla::Document;
use krilla::color::rgb;
use krilla::geom::{PathBuilder, Point, Rect};
use krilla::page::PageSettings;
use krilla::paint::{Fill, Stroke};
use krilla::text::{Font, TextDirection};
use serde::Deserialize;
use std::slice;

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

#[derive(Debug, Deserialize)]
pub struct PdfDocumentInput {
    #[serde(default)]
    pub title: Option<String>,
    pub paper_width: f32,
    pub paper_height: f32,
    #[serde(default = "default_margin")]
    pub margin: f32,
    /// "pages" (Original fixed-position pages) or "flow" (Typed flowing blocks).
    pub mode: String,
    #[serde(default)]
    pub pages: Vec<PdfInputPage>,
    #[serde(default)]
    pub blocks: Vec<PdfFlowBlock>,
}

fn default_margin() -> f32 {
    36.0
}

#[derive(Debug, Deserialize)]
pub struct PdfInputPage {
    #[serde(default)]
    pub rects: Vec<PdfRectItem>,
    #[serde(default)]
    pub strokes: Vec<PdfStrokeItem>,
    #[serde(default)]
    pub runs: Vec<PdfTextRun>,
}

#[derive(Debug, Deserialize)]
pub struct PdfRectItem {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    #[serde(default = "default_border_width")]
    pub stroke_width: f32,
    #[serde(default = "default_border_gray")]
    pub gray: u8,
}

fn default_border_width() -> f32 {
    0.8
}

fn default_border_gray() -> u8 {
    170
}

#[derive(Debug, Deserialize)]
pub struct PdfStrokeItem {
    pub points: Vec<[f32; 2]>,
    #[serde(default = "default_stroke_width")]
    pub width: f32,
}

fn default_stroke_width() -> f32 {
    1.2
}

#[derive(Debug, Deserialize)]
pub struct PdfTextRun {
    pub text: String,
    pub x: f32,
    pub y: f32,
    pub max_width: f32,
    pub font_size: f32,
    pub line_height: f32,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub muted: bool,
}

#[derive(Debug, Deserialize)]
pub struct PdfFlowBlock {
    #[serde(default)]
    pub kind: String,
    pub text: String,
    pub font_size: f32,
    pub line_height: f32,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub keep_with_next: bool,
    #[serde(default)]
    pub space_after: f32,
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

fn draw_rect_border(surface: &mut krilla::surface::Surface<'_>, r: &PdfRectItem) {
    let mut pb = PathBuilder::new();
    pb.move_to(r.x, r.y);
    pb.line_to(r.x + r.width, r.y);
    pb.line_to(r.x + r.width, r.y + r.height);
    pb.line_to(r.x, r.y + r.height);
    pb.close();
    if let Some(path) = pb.finish() {
        surface.set_fill(None);
        surface.set_stroke(Some(Stroke {
            paint: rgb::Color::new(r.gray, r.gray, r.gray).into(),
            width: r.stroke_width,
            ..Default::default()
        }));
        surface.draw_path(&path);
    }
}

fn draw_stroke_poly(surface: &mut krilla::surface::Surface<'_>, s: &PdfStrokeItem) {
    if s.points.len() < 2 {
        return;
    }
    let mut pb = PathBuilder::new();
    pb.move_to(s.points[0][0], s.points[0][1]);
    for pt in &s.points[1..] {
        pb.line_to(pt[0], pt[1]);
    }
    if let Some(path) = pb.finish() {
        surface.set_fill(None);
        surface.set_stroke(Some(Stroke {
            paint: rgb::Color::new(45, 58, 72).into(),
            width: s.width,
            ..Default::default()
        }));
        surface.draw_path(&path);
    }
}

fn draw_text_line(
    surface: &mut krilla::surface::Surface<'_>,
    font: &Font,
    font_size: f32,
    x: f32,
    y: f32,
    line: &str,
    muted: bool,
) {
    // Clear stroke so glyphs are filled at true Regular/Bold weight instead of
    // inheriting a path stroke (which made text appear artificially heavy).
    surface.set_stroke(None);
    let color = if muted {
        rgb::Color::new(95, 95, 95)
    } else {
        rgb::Color::new(22, 22, 22)
    };
    surface.set_fill(Some(Fill {
        paint: color.into(),
        ..Default::default()
    }));
    surface.draw_text(
        Point::from_xy(x, y),
        font.clone(),
        font_size,
        line,
        false,
        TextDirection::Auto,
    );
}

/// Renders a [PdfSpikeModel] using krilla (OpenType shaping + font embedding + vector strokes).
pub fn render_pdf_bytes(model: &PdfSpikeModel, thai_font_bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    let font = Font::new(Data::from(thai_font_bytes), 0)
        .ok_or_else(|| "failed to load TTF font".to_string())?;
    let mut doc = Document::new();
    for page_in in &model.pages {
        let mut page = doc.start_page_with(
            PageSettings::from_wh(page_in.width, page_in.height)
                .ok_or_else(|| "invalid page size".to_string())?,
        );
        let mut surface = page.surface();

        for pts in &page_in.strokes {
            draw_stroke_poly(
                &mut surface,
                &PdfStrokeItem {
                    points: pts.clone(),
                    width: 1.5,
                },
            );
        }

        for run in &page_in.runs {
            let approx_cw = run.font_size * 0.52;
            let lines = break_lines_thai_safe(&run.text, run.max_width, approx_cw);
            for (idx, line) in lines.iter().enumerate() {
                let y = run.y + (idx as f32) * run.line_height;
                draw_text_line(&mut surface, &font, run.font_size, run.x, y, line, false);
            }
        }
        surface.finish();
        page.finish();
    }
    let _ = Rect::from_xywh(0.0, 0.0, 1.0, 1.0);
    doc.finish().map_err(|e| format!("krilla finish error: {e:?}"))
}

/// Renders a full [PdfDocumentInput] (Original fixed pages or Typed flowing blocks).
pub fn render_document_pdf_bytes(
    input: &PdfDocumentInput,
    regular_font_bytes: Vec<u8>,
    bold_font_bytes: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let regular = Font::new(Data::from(regular_font_bytes), 0)
        .ok_or_else(|| "failed to load regular font".to_string())?;
    let bold = if bold_font_bytes.is_empty() {
        regular.clone()
    } else {
        Font::new(Data::from(bold_font_bytes), 0).unwrap_or_else(|| regular.clone())
    };

    let mut doc = Document::new();
    let settings = PageSettings::from_wh(input.paper_width, input.paper_height)
        .ok_or_else(|| "invalid paper size".to_string())?;

    if input.mode == "flow" {
        let printable_w = (input.paper_width - input.margin * 2.0).max(80.0);
        let max_y = input.paper_height - input.margin;
        let mut page = doc.start_page_with(settings.clone());
        let mut surface = page.surface();
        let mut y = input.margin + 18.0;

        if let Some(title) = &input.title {
            if !title.is_empty() {
                let lines = break_lines_thai_safe(title, printable_w, 18.0 * 0.50);
                for line in &lines {
                    draw_text_line(&mut surface, &bold, 18.0, input.margin, y, line, false);
                    y += 24.0;
                }
                y += 8.0;
            }
        }

        for (bi, block) in input.blocks.iter().enumerate() {
            let font = if block.bold { &bold } else { &regular };
            let approx_cw = block.font_size * 0.48;
            let lines = break_lines_thai_safe(&block.text, printable_w, approx_cw);
            let min_needed = if block.keep_with_next && bi + 1 < input.blocks.len() {
                (lines.len() as f32) * block.line_height + block.space_after + 24.0
            } else {
                block.line_height
            };
            if y + min_needed > max_y && y > input.margin + 24.0 {
                surface.finish();
                page.finish();
                page = doc.start_page_with(settings.clone());
                surface = page.surface();
                y = input.margin + block.font_size;
            }
            for line in &lines {
                if y > max_y {
                    surface.finish();
                    page.finish();
                    page = doc.start_page_with(settings.clone());
                    surface = page.surface();
                    y = input.margin + block.font_size;
                }
                draw_text_line(&mut surface, font, block.font_size, input.margin, y, line, block.muted);
                y += block.line_height;
            }
            y += block.space_after;
        }
        surface.finish();
        page.finish();
    } else {
        if input.pages.is_empty() {
            let mut page = doc.start_page_with(settings);
            let surface = page.surface();
            surface.finish();
            page.finish();
        } else {
            for page_in in &input.pages {
                let mut page = doc.start_page_with(settings.clone());
                let mut surface = page.surface();
                for r in &page_in.rects {
                    draw_rect_border(&mut surface, r);
                }
                for s in &page_in.strokes {
                    draw_stroke_poly(&mut surface, s);
                }
                for run in &page_in.runs {
                    let font = if run.bold { &bold } else { &regular };
                    let approx_cw = run.font_size * 0.48;
                    let lines = break_lines_thai_safe(&run.text, run.max_width, approx_cw);
                    for (idx, line) in lines.iter().enumerate() {
                        let y = run.y + (idx as f32) * run.line_height;
                        draw_text_line(&mut surface, font, run.font_size, run.x, y, line, run.muted);
                    }
                }
                surface.finish();
                page.finish();
            }
        }
    }

    doc.finish().map_err(|e| format!("krilla finish error: {e:?}"))
}

/// C-ABI entry point for Flutter FFI. Returns 0 on success, negative on error.
/// Caller must free `*out_ptr` with `asodya_krilla_free_buffer(*out_ptr, *out_len)`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn asodya_krilla_render_pdf(
    model_json_ptr: *const u8,
    model_json_len: usize,
    regular_font_ptr: *const u8,
    regular_font_len: usize,
    bold_font_ptr: *const u8,
    bold_font_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if model_json_ptr.is_null()
        || regular_font_ptr.is_null()
        || out_ptr.is_null()
        || out_len.is_null()
    {
        return -1;
    }
    let json_bytes = unsafe { slice::from_raw_parts(model_json_ptr, model_json_len) };
    let input: PdfDocumentInput = match serde_json::from_slice(json_bytes) {
        Ok(v) => v,
        Err(_) => return -2,
    };
    let regular_font = unsafe { slice::from_raw_parts(regular_font_ptr, regular_font_len) }.to_vec();
    let bold_font = if bold_font_ptr.is_null() || bold_font_len == 0 {
        Vec::new()
    } else {
        unsafe { slice::from_raw_parts(bold_font_ptr, bold_font_len) }.to_vec()
    };

    let pdf = match render_document_pdf_bytes(&input, regular_font, bold_font) {
        Ok(b) => b,
        Err(_) => return -3,
    };

    let mut boxed = pdf.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_ptr = ptr;
        *out_len = len;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn asodya_krilla_free_buffer(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        unsafe {
            let _ = Box::from_raw(slice::from_raw_parts_mut(ptr, len));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn asodya_krilla_alloc(size: usize) -> *mut u8 {
    let mut buf = vec![0u8; size].into_boxed_slice();
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

#[unsafe(no_mangle)]
pub extern "C" fn asodya_krilla_ping() -> i32 {
    41
}

#[cfg(target_arch = "wasm32")]
#[unsafe(no_mangle)]
pub extern "C" fn asodya_krilla_wasm_alloc(size: usize) -> *mut u8 {
    asodya_krilla_alloc(size)
}

#[cfg(target_arch = "wasm32")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn asodya_krilla_wasm_free(ptr: *mut u8, size: usize) {
    unsafe { asodya_krilla_free_buffer(ptr, size) };
}

/// WASM32 entry point: packs `(ptr << 32) | len` into u64 (0 on error).
/// Writes `[out_ptr, out_len]` into linear memory; JS/Dart reads bytes then frees both.
#[cfg(target_arch = "wasm32")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn asodya_krilla_wasm_render_pdf(
    model_json_ptr: *const u8,
    model_json_len: usize,
    regular_font_ptr: *const u8,
    regular_font_len: usize,
    bold_font_ptr: *const u8,
    bold_font_len: usize,
) -> u64 {
    let mut out_ptr: *mut u8 = std::ptr::null_mut();
    let mut out_len: usize = 0;
    let rc = unsafe {
        asodya_krilla_render_pdf(
            model_json_ptr,
            model_json_len,
            regular_font_ptr,
            regular_font_len,
            bold_font_ptr,
            bold_font_len,
            &mut out_ptr,
            &mut out_len,
        )
    };
    if rc != 0 || out_ptr.is_null() {
        return 0;
    }
    ((out_ptr as usize as u64) << 32) | (out_len as u64)
}
