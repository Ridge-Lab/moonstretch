///|
test "FIFO retained PCM counts consumed prefix until storage is compacted" {
  let processor = @moonstretch.Processor::new(8000, 1, adjustable=false)
  processor.put_samples(Array::make(10000, 0.1))
  processor.finish()
  assert_eq(processor.buffered_frames(), 10000)
  assert_eq(processor.receive_samples(2000).length(), 2000)
  assert_eq(processor.num_samples(), 8000)
  assert_eq(processor.buffered_frames(), 10000)
  assert_eq(processor.receive_samples(8000).length(), 8000)
  assert_eq(processor.buffered_frames(), 0)
}
