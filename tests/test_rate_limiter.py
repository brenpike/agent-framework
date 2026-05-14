import sys
sys.path.insert(0, '.')
from src.rate_limiter import rate_limit, RateLimitExceeded
import unittest
from unittest.mock import patch

class TestRateLimiter(unittest.TestCase):
    def test_allows_requests_under_limit(self):
        @rate_limit(max_requests=5)
        def call(): return True
        for _ in range(5):
            self.assertTrue(call())

    def test_raises_when_over_limit(self):
        @rate_limit(max_requests=3)
        def call(): return True
        call(); call(); call()
        with self.assertRaises(RateLimitExceeded):
            call()

    def test_window_resets(self):
        with patch('src.rate_limiter.time') as mock_time:
            mock_time.time.return_value = 100.0
            @rate_limit(max_requests=2, window_seconds=60)
            def call(): return True
            call(); call()
            mock_time.time.return_value = 200.0
            self.assertTrue(call())

    def test_per_key_limits(self):
        @rate_limit(max_requests=1, key=lambda user, **kw: user)
        def call(user): return user
        self.assertEqual(call("alice"), "alice")
        with self.assertRaises(RateLimitExceeded):
            call("alice")
        self.assertEqual(call("bob"), "bob")

    def test_default_error_message(self):
        @rate_limit(max_requests=1)
        def call(): pass
        call()
        with self.assertRaises(RateLimitExceeded):
            call()

    def test_reset_clears_history(self):
        @rate_limit(max_requests=1)
        def call(): return True
        call()
        call.reset()
        self.assertTrue(call())

if __name__ == '__main__':
    unittest.main()
