//! Measured text layout for the PDF (annotations#42).
//!
//! Widths come from shaping with rustybuzz, the shaper Krilla itself uses
//! for `draw_text`, with the same embedded font and size, so a line holds
//! exactly what fits. Line breaks come from ICU (UAX #14), so Thai breaks
//! between words without spaces. A run is a list of styled spans: size,
//! bold, italic, strikethrough and color stay per span.

use icu_segmenter::LineSegmenter;
use rustybuzz::{Face, UnicodeBuffer};
use serde::Deserialize;

/// One styled piece of text: a span of an editor text item or a block.
#[derive(Debug, Clone, Deserialize)]
pub struct PdfSpan {
    pub text: String,
    pub size: f32,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub strike: bool,
    /// 0xAARRGGBB.
    #[serde(default = "default_ink")]
    pub argb: u32,
}

/// The default text color, as the renderer drew text before spans.
pub fn default_ink() -> u32 {
    0xFF16_1616
}

/// The two embedded faces, measured the way Krilla draws them.
pub struct Metrics<'a> {
    pub regular: Face<'a>,
    pub bold: Face<'a>,
}

impl<'a> Metrics<'a> {
    pub fn face(&self, bold: bool) -> &Face<'a> {
        if bold { &self.bold } else { &self.regular }
    }

    fn scale(&self, bold: bool, size: f32) -> f32 {
        size / self.face(bold).units_per_em() as f32
    }

    /// The advance width of [text] in points.
    pub fn width(&self, text: &str, bold: bool, size: f32) -> f32 {
        if text.is_empty() {
            return 0.0;
        }
        let mut buffer = UnicodeBuffer::new();
        buffer.push_str(text);
        buffer.guess_segment_properties();
        let out = rustybuzz::shape(self.face(bold), &[], buffer);
        let units: i32 = out.glyph_positions().iter().map(|p| p.x_advance).sum();
        units as f32 * self.scale(bold, size)
    }

    /// The ascent above the baseline in points.
    pub fn ascent(&self, bold: bool, size: f32) -> f32 {
        self.face(bold).ascender() as f32 * self.scale(bold, size)
    }

    /// The natural line height of the font: ascent, descent and line gap.
    pub fn line_height(&self, bold: bool, size: f32) -> f32 {
        let f = self.face(bold);
        (f.ascender() as f32 - f.descender() as f32 + f.line_gap() as f32) * self.scale(bold, size)
    }

    /// Strikethrough offset above the baseline and its thickness, in points.
    pub fn strikeout(&self, bold: bool, size: f32) -> (f32, f32) {
        let s = self.scale(bold, size);
        match self.face(bold).strikeout_metrics() {
            Some(m) if m.thickness > 0 => (m.position as f32 * s, m.thickness as f32 * s),
            _ => (size * 0.3, size * 0.06),
        }
    }
}

/// A part of a line in one span: its text, its span, where it starts.
#[derive(Debug, Clone, PartialEq)]
pub struct Piece {
    pub text: String,
    pub span: usize,
    pub x: f32,
    pub width: f32,
}

#[derive(Debug, Clone)]
pub struct Line {
    pub pieces: Vec<Piece>,
    /// Ascent of the tallest span on the line: the baseline is this far
    /// below the top of the line.
    pub ascent: f32,
    /// The line height of the tallest span on the line.
    pub height: f32,
}

impl Line {
    pub fn width(&self) -> f32 {
        self.pieces.last().map_or(0.0, |p| p.x + p.width)
    }

    pub fn text(&self) -> String {
        self.pieces.iter().map(|p| p.text.as_str()).collect()
    }
}

/// Lays out [spans] in lines of at most [max_width] points. A line breaks
/// only at a UAX #14 opportunity and at `\n`; a word wider than the line
/// stays whole on its own line. Trailing spaces never count toward the fit.
pub fn layout(spans: &[PdfSpan], max_width: f32, m: &Metrics) -> Vec<Line> {
    let mut full = String::new();
    let mut ranges = Vec::with_capacity(spans.len());
    for s in spans {
        let start = full.len();
        full.push_str(&s.text);
        ranges.push((start, full.len()));
    }
    let span_at = |pos: usize| -> usize {
        ranges
            .iter()
            .position(|&(a, b)| pos >= a && pos < b)
            .unwrap_or(spans.len().saturating_sub(1))
    };
    let segmenter = LineSegmenter::new_auto(Default::default());
    let mut lines = Vec::new();
    let mut para_start = 0usize;
    let paragraphs: Vec<(usize, usize)> = {
        let mut out = Vec::new();
        for (i, ch) in full.char_indices() {
            if ch == '\n' {
                out.push((para_start, i));
                para_start = i + 1;
            }
        }
        out.push((para_start, full.len()));
        out
    };
    for (ps, pe) in paragraphs {
        let para = &full[ps..pe];
        let mut current: Vec<Piece> = Vec::new();
        let mut line_w = 0.0f32;
        let mut prev = 0usize;
        let empty_span = span_at(ps.min(full.len().saturating_sub(1)));
        let breaks: Vec<usize> = segmenter.segment_str(para).collect();
        for b in breaks {
            if b <= prev {
                continue;
            }
            let pieces = split(&full, ps + prev, ps + b, &ranges, spans, m);
            prev = b;
            let seg_w: f32 = pieces.iter().map(|p| p.width).sum();
            let fit_w = seg_w - trailing_space_width(&pieces, spans, m);
            if !current.is_empty() && line_w + fit_w > max_width {
                lines.push(finish(std::mem::take(&mut current), spans, m, empty_span));
                line_w = 0.0;
            }
            for mut p in pieces {
                p.x = line_w;
                line_w += p.width;
                match current.last_mut() {
                    Some(last) if last.span == p.span => {
                        last.text.push_str(&p.text);
                        last.width += p.width;
                    }
                    _ => current.push(p),
                }
            }
        }
        lines.push(finish(current, spans, m, empty_span));
    }
    lines
}

/// The pieces of `full[a..b]`, cut at span boundaries, with their widths.
fn split(
    full: &str,
    a: usize,
    b: usize,
    ranges: &[(usize, usize)],
    spans: &[PdfSpan],
    m: &Metrics,
) -> Vec<Piece> {
    let mut out = Vec::new();
    for (i, &(s, e)) in ranges.iter().enumerate() {
        let (lo, hi) = (a.max(s), b.min(e));
        if lo < hi {
            let text = full[lo..hi].to_string();
            let width = m.width(&text, spans[i].bold, spans[i].size);
            out.push(Piece {
                text,
                span: i,
                x: 0.0,
                width,
            });
        }
    }
    out
}

fn trailing_space_width(pieces: &[Piece], spans: &[PdfSpan], m: &Metrics) -> f32 {
    let Some(last) = pieces.last() else {
        return 0.0;
    };
    let trimmed = last.text.trim_end();
    if trimmed.len() == last.text.len() {
        return 0.0;
    }
    let s = &spans[last.span];
    last.width - m.width(trimmed, s.bold, s.size)
}

/// Drops trailing spaces of the line and sets its ascent and height from the
/// tallest span on it.
fn finish(mut pieces: Vec<Piece>, spans: &[PdfSpan], m: &Metrics, empty_span: usize) -> Line {
    while let Some(last) = pieces.last_mut() {
        let trimmed = last.text.trim_end().to_string();
        if trimmed.is_empty() {
            pieces.pop();
            continue;
        }
        if trimmed.len() != last.text.len() {
            let s = &spans[last.span];
            last.width = m.width(&trimmed, s.bold, s.size);
            last.text = trimmed;
        }
        break;
    }
    let used: Vec<usize> = if pieces.is_empty() {
        vec![empty_span]
    } else {
        pieces.iter().map(|p| p.span).collect()
    };
    let mut ascent = 0.0f32;
    let mut height = 0.0f32;
    for i in used {
        if let Some(s) = spans.get(i) {
            ascent = ascent.max(m.ascent(s.bold, s.size));
            height = height.max(m.line_height(s.bold, s.size));
        }
    }
    Line {
        pieces,
        ascent,
        height,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REGULAR: &[u8] = include_bytes!(
        "../../../common/annotations_shared/lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Regular.ttf"
    );
    const BOLD: &[u8] = include_bytes!(
        "../../../common/annotations_shared/lib/presentation/frontend/assets/fonts/IBMPlexSansThai-Bold.ttf"
    );

    fn metrics() -> Metrics<'static> {
        Metrics {
            regular: Face::from_slice(REGULAR, 0).unwrap(),
            bold: Face::from_slice(BOLD, 0).unwrap(),
        }
    }

    fn span(text: &str, size: f32) -> PdfSpan {
        PdfSpan {
            text: text.into(),
            size,
            bold: false,
            italic: false,
            strike: false,
            argb: default_ink(),
        }
    }

    #[test]
    fn measured_width_follows_the_glyphs_not_the_character_count() {
        let m = metrics();
        let narrow = m.width("iiiiiiiiii", false, 10.0);
        let wide = m.width("WWWWWWWWWW", false, 10.0);
        assert!(wide > narrow * 2.0, "{wide} vs {narrow}");
        assert!((m.width("ab", false, 20.0) - 2.0 * m.width("ab", false, 10.0)).abs() < 0.01);
        assert!(m.width("Bold", true, 10.0) > m.width("Bold", false, 10.0));
    }

    #[test]
    fn a_line_holds_what_fits_and_breaks_between_words() {
        let m = metrics();
        let text = "Field notes on river sampling. Three sites, two";
        let full = m.width("Field notes on river sampling. Three sites,", false, 10.0);
        let lines = layout(&[span(text, 10.0)], full + 0.5, &m);
        assert_eq!(
            lines[0].text(),
            "Field notes on river sampling. Three sites,"
        );
        assert_eq!(lines[1].text(), "two");
        assert!(lines[0].width() <= full + 0.5);
    }

    #[test]
    fn thai_breaks_between_words_without_spaces() {
        let m = metrics();
        let text = "การบันทึกข้อความภาษาไทยในระบบเอกสารดิจิทัล";
        let lines = layout(&[span(text, 12.0)], m.width(text, false, 12.0) / 2.0, &m);
        assert!(lines.len() >= 2);
        assert_eq!(lines.iter().map(|l| l.text()).collect::<String>(), text);
        for l in &lines {
            assert!(!l.text().starts_with('\u{0E31}') && !l.text().starts_with('\u{0E34}'));
        }
    }

    #[test]
    fn spans_keep_their_own_size_and_the_line_takes_the_tallest() {
        let m = metrics();
        let mut big = span("BIG", 24.0);
        big.bold = true;
        let lines = layout(
            &[span("small ", 10.0), big, span(" tail", 10.0)],
            1000.0,
            &m,
        );
        assert_eq!(lines.len(), 1);
        let p = &lines[0].pieces;
        assert_eq!(p.iter().map(|x| x.span).collect::<Vec<_>>(), vec![0, 1, 2]);
        assert!((p[1].x - m.width("small ", false, 10.0)).abs() < 0.01);
        assert!((lines[0].height - m.line_height(true, 24.0)).abs() < 0.01);
    }

    #[test]
    fn new_lines_are_kept_and_empty_lines_have_height() {
        let m = metrics();
        let lines = layout(&[span("one\n\nthree", 10.0)], 1000.0, &m);
        assert_eq!(
            lines.iter().map(|l| l.text()).collect::<Vec<_>>(),
            vec!["one", "", "three"]
        );
        assert!(lines[1].height > 0.0);
    }
}
