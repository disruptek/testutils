import unittest

suite "goats":
  test "pigs":
    discard
    check true

  test "horses":
    expect ValueError:
      discard
      raise newException(ValueError, "you made an error")
