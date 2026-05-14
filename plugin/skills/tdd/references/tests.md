# Good and Bad Tests

## The core rule

Tests verify behavior through public interfaces. Code internals can change completely — tests shouldn't care.

A good test reads like a specification. "user can checkout with valid cart" tells you exactly what capability exists.

## Good tests

```python
# GOOD: Tests observable behavior via public interface
def test_user_can_checkout_with_valid_cart():
    cart = Cart()
    cart.add(product(id="p1", price=9.99))
    result = checkout(cart, payment_method=credit_card())
    assert result.status == "confirmed"
    assert result.total == 9.99
```

Characteristics:
- Uses public API only
- Would survive renaming internal functions
- Name describes WHAT, not HOW
- One logical assertion (or closely related assertions about one outcome)

## Bad tests

```python
# BAD: Tests implementation detail (internal call)
def test_checkout_calls_payment_service():
    with patch("cart.payment_service.process") as mock:
        checkout(cart, payment)
        mock.assert_called_once_with(cart.total)

# BAD: Verifies through external means instead of interface
def test_create_user_saves_to_db():
    create_user(name="Alice")
    row = db.execute("SELECT * FROM users WHERE name=?", ["Alice"]).fetchone()
    assert row is not None

# GOOD: Verifies through interface
def test_create_user_makes_user_retrievable():
    user = create_user(name="Alice")
    retrieved = get_user(user.id)
    assert retrieved.name == "Alice"
```

Red flags:
- Test name contains "calls", "invokes", "saves to", "queries"
- Test patches/mocks something inside your own module
- Test breaks when you rename an internal function without changing behavior
- Test uses direct DB/file/network access to verify state
