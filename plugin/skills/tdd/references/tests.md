# Good and Bad Tests

## The core rule

Tests verify behavior through public interfaces. Code internals can change completely — tests shouldn't care.

A good test reads like a specification. "UserCanCheckoutWithValidCart" tells you exactly what capability exists.

## Good tests

```csharp
// GOOD: Tests observable behavior via public interface
[Fact]
public void UserCanCheckoutWithValidCart()
{
    var cart = new Cart();
    cart.Add(Product(id: "p1", price: 9.99m));
    var result = Checkout(cart, paymentMethod: CreditCard());
    Assert.Equal("confirmed", result.Status);
    Assert.Equal(9.99m, result.Total);
}
```

Characteristics:
- Uses public API only
- Would survive renaming internal functions
- Name describes WHAT, not HOW
- One logical assertion (or closely related assertions about one outcome)

## Bad tests

```csharp
// BAD: Tests implementation detail (internal call)
[Fact]
public void CheckoutCallsPaymentService()
{
    var mock = new Mock<IPaymentService>();
    Checkout(cart, payment);
    mock.Verify(m => m.Process(cart.Total), Times.Once);
}

// BAD: Verifies through external means instead of interface
[Fact]
public void CreateUserSavesToDb()
{
    CreateUser(name: "Alice");
    var row = db.Execute("SELECT * FROM users WHERE name=@name", new { name = "Alice" }).FirstOrDefault();
    Assert.NotNull(row);
}

// GOOD: Verifies through interface
[Fact]
public void CreateUserMakesUserRetrievable()
{
    var user = CreateUser(name: "Alice");
    var retrieved = GetUser(user.Id);
    Assert.Equal("Alice", retrieved.Name);
}
```

Red flags:
- Test name contains "calls", "invokes", "saves to", "queries"
- Test uses Moq/NSubstitute to mock something inside your own assembly
- Test breaks when you rename an internal function without changing behavior
- Test uses direct DB/file/network access to verify state
