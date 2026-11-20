use pdf_krilla_spike::{PdfSpikeModel, PdfSpikePage, PdfSpikeTextRun, render_pdf_bytes};
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    let font_path = args.get(1).expect("usage: pdf_krilla_spike <font.ttf> <out.pdf>");
    let out_path = args.get(2).expect("usage: pdf_krilla_spike <font.ttf> <out.pdf>");
    let font_bytes = fs::read(font_path).expect("read font");

    let model = PdfSpikeModel {
        pages: vec![PdfSpikePage {
            width: 595.0,
            height: 842.0,
            strokes: vec![vec![[48.0, 190.0], [547.0, 190.0]]],
            runs: vec![
                PdfSpikeTextRun {
                    text: "กิ๊ กี๊ กึ๊ กื๊".to_string(),
                    x: 48.0,
                    y: 72.0,
                    max_width: 499.0,
                    font_size: 18.0,
                    line_height: 26.0,
                },
                PdfSpikeTextRun {
                    text: "การบันทึกข้อความภาษาไทยในระบบเอกสารดิจิทัลต้องรองรับการวางตำแหน่งสระและวรรณยุกต์อย่างถูกต้องรวมถึงการตัดคำขึ้นบรรทัดใหม่โดยไม่ตัดกลางคำเพื่อให้ผู้อ่านสามารถอ่านและค้นหาข้อความได้อย่างสมบูรณ์".to_string(),
                    x: 48.0,
                    y: 112.0,
                    max_width: 460.0,
                    font_size: 14.0,
                    line_height: 22.0,
                },
            ],
        }],
    };

    let pdf = render_pdf_bytes(&model, font_bytes).expect("render pdf");
    fs::write(out_path, &pdf).expect("write pdf");
    println!("WROTE {} bytes to {}", pdf.len(), out_path);
}
