//! Referent LogC3/AWG3 LUT color adaptation for scene-linear input.
//!
//! The shipped Referent LUT is a full display rendering transform. Applying
//! its output before Negs' film model stacks two tone-rendering stages. To
//! borrow its color mapping at the input instead, evaluate the LUT in its
//! intended LogC3/AWG3 space, decode the Rec.709 result, then restore the
//! source scene luminance. This keeps the LUT's hue/chroma mapping while
//! leaving exposure and highlight/shadow roll-off to the Negs pipeline.

use std::{collections::HashMap, fs, path::{Path, PathBuf}, sync::{Arc, Mutex, OnceLock}};

use rayon::prelude::*;
use spektrafilm_gpu::Lut3D;
use spektrafilm_math::{image::ImageBuf, precision::{from_f32, to_f32}, lut::trilinear_3d};

const SRGB_TO_AWG3: [[f32; 3]; 3] = [
    [0.631_362_1, 0.270_812_36, 0.097_915_89],
    [0.036_753_58, 0.793_071_75, 0.170_135_22],
    [0.017_339_19, 0.148_795_57, 0.833_812_4],
];
static CUBE_CACHE: OnceLock<Mutex<HashMap<PathBuf, (u64, u128, Arc<Lut3D>)>>> = OnceLock::new();

/// Parse a .cube file, normalizing its conventional red-fastest row order to
/// the core interpolator's red-major layout. Domain remaps are deliberately
/// rejected: the selected Referent LUT uses the standard [0, 1] domain.
pub fn load_cube(path: &Path) -> Result<Arc<Lut3D>, String> {
    let metadata = fs::metadata(path)
        .map_err(|e| format!("Cannot read Referent LUT {}: {e}", path.display()))?;
    let modified = metadata.modified().ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |time| time.as_nanos());
    let cache = CUBE_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some((len, stamp, lut)) = cache.lock().unwrap_or_else(|p| p.into_inner()).get(path)
        && *len == metadata.len() && *stamp == modified
    {
        return Ok(lut.clone());
    }
    let text = fs::read_to_string(path)
        .map_err(|e| format!("Cannot read Referent LUT {}: {e}", path.display()))?;
    let mut size = None;
    let mut domain_min = [0.0f32; 3];
    let mut domain_max = [1.0f32; 3];
    let mut values = Vec::<[f32; 3]>::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() || line.starts_with("TITLE") { continue; }
        if let Some(rest) = line.strip_prefix("DOMAIN_MIN") {
            domain_min = parse_triplet(rest, "DOMAIN_MIN")?;
            continue;
        }
        if let Some(rest) = line.strip_prefix("DOMAIN_MAX") {
            domain_max = parse_triplet(rest, "DOMAIN_MAX")?;
            continue;
        }
        if let Some(rest) = line.strip_prefix("LUT_3D_SIZE") {
            let n: usize = rest.trim().parse().map_err(|_| "Invalid LUT_3D_SIZE".to_owned())?;
            if !(2..=129).contains(&n) { return Err(format!("Unsupported 3D LUT size: {n}")); }
            size = Some(n);
            continue;
        }
        if line.starts_with("LUT_1D_SIZE") { return Err("Referent input requires a 3D .cube LUT".into()); }
        let mut parts = line.split_whitespace();
        let Some(r) = parts.next() else { continue };
        let (Ok(r), Some(g), Some(b)) = (r.parse::<f32>(), parts.next(), parts.next()) else {
            return Err(format!("Invalid LUT data row: {line}"));
        };
        let (Ok(g), Ok(b)) = (g.parse::<f32>(), b.parse::<f32>()) else {
            return Err(format!("Invalid LUT data row: {line}"));
        };
        if parts.next().is_some() || !r.is_finite() || !g.is_finite() || !b.is_finite() {
            return Err(format!("Invalid LUT data row: {line}"));
        }
        values.push([r, g, b]);
    }
    if domain_min != [0.0; 3] || domain_max != [1.0; 3] {
        return Err("Referent input requires a .cube LUT with a [0, 1] domain".into());
    }
    let n = size.ok_or("Missing LUT_3D_SIZE")?;
    if values.len() != n * n * n {
        return Err(format!("Expected {} LUT entries, found {}", n * n * n, values.len()));
    }
    let mut data = vec![0.0; values.len() * 3];
    // .cube rows enumerate red fastest; Lut3D indexes blue fastest.
    for b in 0..n { for g in 0..n { for r in 0..n {
        let src = (b * n * n + g * n + r) * 3;
        let dst = (r * n * n + g * n + b) * 3;
        data[dst..dst + 3].copy_from_slice(&values[src / 3]);
    }}}
    let lut = Arc::new(Lut3D { size: n as u32, data });
    cache.lock().unwrap_or_else(|p| p.into_inner())
        .insert(path.to_path_buf(), (metadata.len(), modified, lut.clone()));
    Ok(lut)
}

fn parse_triplet(rest: &str, name: &str) -> Result<[f32; 3], String> {
    let values: Result<Vec<f32>, _> = rest.split_whitespace().map(str::parse).collect();
    let values = values.map_err(|_| format!("Invalid {name}"))?;
    let [a, b, c]: [f32; 3] = values.try_into().map_err(|_| format!("Invalid {name}"))?;
    if !a.is_finite() || !b.is_finite() || !c.is_finite() {
        return Err(format!("Invalid {name}"));
    }
    Ok([a, b, c])
}

/// Apply only Referent's color remapping to a scene-linear sRGB image.
///
/// `exposure_ev` chooses the LUT's chromatic response at the same exposure
/// used by the film pipeline; it is not baked into the returned pixels. The
/// output luminance is restored to the source luminance so the film model
/// receives scene-referred values rather than Referent's Rec.709 tone curve.
pub fn apply_color_only(image: &ImageBuf, lut: &Lut3D, exposure_ev: f64) -> ImageBuf {
    let gain = 2.0f64.powf(exposure_ev) as f32;
    let mut output = image.clone();
    output.par_pixels_mut().for_each(|px| {
        let source = [to_f32(px[0]), to_f32(px[1]), to_f32(px[2])];
        let exposed = [source[0] * gain, source[1] * gain, source[2] * gain];
        let awg = [
            SRGB_TO_AWG3[0][0] * exposed[0] + SRGB_TO_AWG3[0][1] * exposed[1] + SRGB_TO_AWG3[0][2] * exposed[2],
            SRGB_TO_AWG3[1][0] * exposed[0] + SRGB_TO_AWG3[1][1] * exposed[1] + SRGB_TO_AWG3[1][2] * exposed[2],
            SRGB_TO_AWG3[2][0] * exposed[0] + SRGB_TO_AWG3[2][1] * exposed[1] + SRGB_TO_AWG3[2][2] * exposed[2],
        ];
        let logc = awg.map(logc3_encode_ei800);
        let rendered = trilinear_3d(&lut.data, lut.size as usize, logc[0], logc[1], logc[2]);
        // Referent writes an SDR display-referred Rec.709 image. To remove
        // that display rendering before Negs' film stage, invert the
        // BT.1886 display EOTF (gamma 2.4), not the BT.709 scene-light OETF.
        // The latter shifts the LUT's RGB ratios and therefore its color.
        let display_linear = rendered.map(|v| v.max(0.0).powf(2.4));
        // Rec.709 linear-light luma. Near black, retain the source to avoid
        // amplifying noise or undefined chroma in the LUT's black endpoint.
        let source_y = 0.2126 * exposed[0] + 0.7152 * exposed[1] + 0.0722 * exposed[2];
        let rendered_y = 0.2126 * display_linear[0] + 0.7152 * display_linear[1] + 0.0722 * display_linear[2];
        if source_y <= 1e-6 || rendered_y <= 1e-6 || !rendered_y.is_finite() {
            return;
        }
        let scale = source_y / rendered_y;
        for c in 0..3 {
            // Remove LUT luminance/tone response and restore original scene
            // light. Undo the exposure used only to choose the LUT sample.
            px[c] = from_f32((display_linear[c] * scale / gain).max(0.0));
        }
    });
    output
}

#[inline]
fn logc3_encode_ei800(x: f32) -> f32 {
    const CUT: f32 = 0.010_591;
    if x > CUT {
        0.247_190 * (5.555_556 * x + 0.052_272).log10() + 0.385_537
    } else {
        5.367_655 * x + 0.092_809
    }
}
