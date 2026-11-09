///|
/// WSOLA window/search profiles. Speech reduces lookahead; Music uses longer
/// overlap and a denser alignment search. These are tradeoffs, not quality scores.
pub(all) enum Quality {
  Speech
  Balanced
  Music
} derive(Debug, Eq)

///|
pub extend Quality with Eq::{equal, not_equal}

///|
pub extend Quality with @debug.Debug::{to_repr}

///|
fn Quality::hop_ms(self : Quality) -> Int32 {
  match self {
    Speech => 10
    Balanced => 20
    Music => 40
  }
}

///|
fn Quality::search_ms(self : Quality) -> Int32 {
  match self {
    Speech => 5
    Balanced => 10
    Music => 15
  }
}

///|
fn Quality::quick(self : Quality) -> Bool {
  self != Music
}
