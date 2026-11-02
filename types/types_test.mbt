///|
test "accept valid formats and finite full frames" {
  @types.validate_format(8000, 1)
  @types.validate_format(192000, 8)
  @types.validate_samples([0.0, -0.5, 0.5, 1.0], 2)
  @types.validate_ratio(1.0, 0.5, 2.0, "tempo")
}

///|
test "reject malformed frames without state mutation" {
  let bad = try {
    @types.validate_samples([0.1], 2)
    false
  } catch {
    _ => true
  }
  assert_true(bad)
  let format = try {
    @types.validate_format(0, 1)
    false
  } catch {
    _ => true
  }
  assert_true(format)
  let ratio = try {
    @types.validate_ratio(0.0, 0.5, 2.0, "tempo")
    false
  } catch {
    _ => true
  }
  assert_true(ratio)
}
