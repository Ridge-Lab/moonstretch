///|
extern "js" fn host_fail(message : String) -> Unit =
  #| (message) => { throw new Error(message); }
