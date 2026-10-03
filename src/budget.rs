//! Token/cost accounting: the `[limits]` ceilings, per-model pricing, and the
//! model-aware auto-compact threshold.

use crate::config::{Limits, Pricing};

/// USD per 1M tokens for one model.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rates {
    pub input: f64,
    pub output: f64,
}

/// Used when a model matches neither `[pricing]` nor the built-in table. Kept
/// at the old blended 0.75 so an unknown model's estimate never moves.
pub const FALLBACK: Rates = Rates {
    input: 0.75,
    output: 0.75,
};

/// Built-in prices in USD per 1M (input, output).
///
/// Matched as a *substring* of the lowercased model name, longest pattern
/// wins — so `gpt-4o-mini` beats `gpt-4o` beats `gpt-4`, and the same entry
/// serves `anthropic/claude-sonnet-4` and a bare `claude-sonnet-4`.
///
/// ponytail: hand-maintained and approximate, and deliberately so. These are
/// guardrail estimates for `[limits] max_cost_usd`, not billing — nobody
/// reconciles a dollar figure from this against an invoice. Real numbers go in
/// `[pricing]`. Refresh the table when a flagship price moves; a hosted price
/// lookup is the upgrade path if this ever needs to be authoritative.
const BUILTIN: &[(&str, f64, f64)] = &[
    ("claude-opus", 15.0, 75.0),
    ("claude-sonnet", 3.0, 15.0),
    ("claude-haiku", 0.8, 4.0),
    ("gemini-2.5-pro", 1.25, 10.0),
    ("gemini-2.5-flash", 0.3, 2.5),
    ("gpt-4o-mini", 0.15, 0.6),
    ("gpt-4.1-mini", 0.4, 1.6),
    ("gpt-4o", 2.5, 10.0),
    ("gpt-4.1", 2.0, 8.0),
    ("gpt-4", 30.0, 60.0),
    ("o3-mini", 1.1, 4.4),
    ("deepseek", 0.27, 1.1),
    ("llama-3.3-70b", 0.12, 0.3),
    ("llama-3.1-8b", 0.06, 0.06),
    ("mistral", 0.25, 0.25),
    ("qwen", 0.2, 0.6),
    ("kimi", 0.6, 2.5),
];

/// Built-in rate for `model`, or [`FALLBACK`].
pub fn builtin_rate(model: &str) -> Rates {
    let m = model.to_ascii_lowercase();
    BUILTIN
        .iter()
        .filter(|(pat, _, _)| m.contains(*pat))
        .max_by_key(|(pat, _, _)| pat.len())
        .map(|(_, i, o)| Rates {
            input: *i,
            output: *o,
        })
        .unwrap_or(FALLBACK)
}

/// Resolve rates for `model`: longest matching `[pricing]` key first, then the
/// built-in table, then [`FALLBACK`].
pub fn rate_for(model: &str, pricing: &Pricing) -> Rates {
    if !pricing.is_empty() {
        let m = model.to_ascii_lowercase();
        if let Some((_, p)) = pricing
            .0
            .iter()
            .filter(|(k, _)| m.contains(&k.to_ascii_lowercase()))
            .max_by_key(|(k, _)| k.len())
        {
            return Rates {
                input: p.input,
                output: p.output,
            };
        }
    }
    builtin_rate(model)
}

/// Estimated cost in USD for the given cumulative token counts.
///
/// `prompt_tokens` must already be the *billable* prompt count (see
/// `Usage::billable_prompt`) — cache hits and cache writes are real tokens
/// even when a provider reports them outside `prompt_tokens`.
pub fn estimate_cost(
    model: &str,
    pricing: &Pricing,
    prompt_tokens: u64,
    completion_tokens: u64,
) -> f64 {
    let r = rate_for(model, pricing);
    (prompt_tokens as f64 / 1_000_000.0) * r.input
        + (completion_tokens as f64 / 1_000_000.0) * r.output
}

/// The ceiling that has been crossed, with a sentence telling the user which
/// one to raise. `None` = no ceiling set, or still under both.
pub fn exceeded(
    l: &Limits,
    model: &str,
    pricing: &Pricing,
    prompt: u64,
    completion: u64,
) -> Option<String> {
    let path = crate::config::Config::toml_path();
    let path = path.display();
    if let Some(cap) = l.max_tokens {
        let total = prompt.saturating_add(completion);
        if total > cap {
            return Some(format!(
                "token budget reached: {total} of {cap} tokens used. \
                 Raise `[limits] max_tokens` in {path} to continue, or start a fresh session."
            ));
        }
    }
    if let Some(cap) = l.max_cost_usd {
        let cost = estimate_cost(model, pricing, prompt, completion);
        if cost > cap {
            let rates = rate_for(model, pricing);
            return Some(format!(
                "cost budget reached: ~${cost:.4} of ~${cap:.4} used \
                 (at ${:.2}/1M in, ${:.2}/1M out for `{model}`). \
                 Raise `[limits] max_cost_usd` in {path}, or pin a \
                 `[pricing.\"{model}\"]` rate, to continue.",
                rates.input, rates.output
            ));
        }
    }
    None
}

/// Fraction of the context window at which auto-compaction fires.
pub const COMPACT_AT_FRACTION: f64 = 0.8;

/// Model-aware compact threshold: 80% of the assumed context window, with a
/// sane floor so tiny advertised windows don't thrash.
pub fn compact_threshold(ctx_window: u64) -> u64 {
    let threshold = (ctx_window as f64 * COMPACT_AT_FRACTION) as u64;
    threshold.max(4_000)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::ModelPrice;
    use std::collections::BTreeMap;

    fn limits(max_tokens: Option<u64>, max_cost_usd: Option<f64>) -> Limits {
        Limits {
            max_tokens,
            max_cost_usd,
            ..Default::default()
        }
    }

    const NONE: &Pricing = &Pricing(BTreeMap::new());

    #[test]
    fn no_ceilings_never_blocks() {
        assert!(exceeded(&Limits::default(), "m", NONE, 10_000_000, 10_000_000).is_none());
        assert!(exceeded(&limits(Some(1_000), None), "m", NONE, 600, 300).is_none());
        assert!(exceeded(&limits(None, Some(0.001)), "m", NONE, 10, 10).is_none());
    }

    #[test]
    fn token_ceiling_blocks_past_the_cap() {
        let l = limits(Some(1_000), None);
        // total 1100 > 1000
        let msg = exceeded(&l, "m", NONE, 600, 500).expect("blocked");
        assert!(msg.contains("token budget reached"), "{msg}");
        assert!(msg.contains("max_tokens"), "{msg}");
    }

    #[test]
    fn cost_ceiling_blocks_past_the_cap() {
        // Unknown model -> FALLBACK 0.75/1M. 1000 prompt tokens = $0.00075.
        let l = limits(None, Some(0.0005));
        let msg = exceeded(&l, "some-unknown-model", NONE, 1_000, 0).expect("blocked");
        assert!(msg.contains("cost budget reached"), "{msg}");
        assert!(msg.contains("max_cost_usd"), "{msg}");
        // The message now names the rates it used, so the number is checkable.
        assert!(msg.contains("0.75"), "{msg}");
    }

    #[test]
    fn input_and_output_are_priced_separately() {
        // Output is 4x input for gpt-4o, so 1M of each must not be treated
        // as one blended bucket.
        let prompt = estimate_cost("gpt-4o", NONE, 1_000_000, 0);
        let completion = estimate_cost("gpt-4o", NONE, 0, 1_000_000);
        assert!((prompt - 2.5).abs() < 1e-9, "prompt was {prompt}");
        assert!(
            (completion - 10.0).abs() < 1e-9,
            "completion was {completion}"
        );
        assert!(completion > prompt * 3.0);
    }

    #[test]
    fn longest_matching_pattern_wins() {
        // gpt-4o-mini ($0.15/$0.60) must not be priced as gpt-4o ($2.50/$10).
        let cheap = estimate_cost("openai/gpt-4o-mini", NONE, 1_000_000, 0);
        let dear = estimate_cost("openai/gpt-4o", NONE, 1_000_000, 0);
        assert!((cheap - 0.15).abs() < 1e-9, "got {cheap}");
        assert!((dear - 2.5).abs() < 1e-9, "got {dear}");
        // Prefix paths resolve to the same row as the bare name.
        assert_eq!(
            rate_for("anthropic/claude-sonnet-4", NONE),
            rate_for("claude-sonnet-4", NONE)
        );
    }

    #[test]
    fn unknown_model_falls_back_without_panicking() {
        assert_eq!(rate_for("", NONE), FALLBACK);
        assert_eq!(rate_for("stealth/ox-alpha", NONE), FALLBACK);
        assert_eq!(estimate_cost("stealth/ox-alpha", NONE, 0, 0).abs(), 0.0);
    }

    #[test]
    fn pricing_override_beats_the_builtin_table() {
        let mut p = BTreeMap::new();
        p.insert(
            "gpt-4o".to_string(),
            ModelPrice {
                input: 1.0,
                output: 2.0,
            },
        );
        let p = Pricing(p);
        let c = estimate_cost("openai/gpt-4o", &p, 1_000_000, 1_000_000);
        assert!((c - 3.0).abs() < 1e-9, "got {c}");
        // A model with no override still uses the built-in table.
        assert!((estimate_cost("claude-sonnet-4", &p, 1_000_000, 0) - 3.0).abs() < 1e-9);
        // An empty override table changes nothing.
        assert!((estimate_cost("gpt-4o", NONE, 1_000_000, 0) - 2.5).abs() < 1e-9);
    }

    #[test]
    fn estimate_scales_with_tokens() {
        assert!(estimate_cost("m", NONE, 10_000, 10_000) > estimate_cost("m", NONE, 1_000, 1_000));
        assert!(estimate_cost("m", NONE, 0, 0).abs() < f64::EPSILON);
    }

    #[test]
    fn compact_threshold_is_fraction_with_floor() {
        assert_eq!(compact_threshold(128_000), 102_400);
        // A tiny window still gets a usable floor to avoid thrash.
        assert_eq!(compact_threshold(1_000), 4_000);
    }
}
