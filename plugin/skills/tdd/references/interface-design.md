# Interface Design for Testability

The test is the first caller — shape the interface before the implementation, and an awkward-to-test design surfaces as an awkward-to-use one.

## 1. Accept dependencies, don't create them

Inject collaborators so the test can substitute them. Code that `new`s its dependency forces the test to reach the real thing.

```csharp
// GOOD — collaborator is injected, test passes a fake
public Order PlaceOrder(Cart cart, IPaymentGateway gateway)
{
    return gateway.Charge(cart.Total);
}

// BAD — collaborator created internally, test cannot substitute it
public Order PlaceOrder(Cart cart)
{
    var gateway = new StripeGateway(Settings.ApiKey);
    return gateway.Charge(cart.Total);
}
```

## 2. Return results, don't mutate

Return a value the test can assert. A `void` method that mutates shared state forces the test to inspect that state from the outside.

```csharp
// GOOD — returns the total, the test asserts on the return value
public decimal ApplyDiscount(Cart cart, decimal percent)
{
    return cart.Subtotal * (1 - percent);
}

// BAD — void side effect on shared state, test must dig for it
public void ApplyDiscount(Cart cart, decimal percent)
{
    _globalCart.Total = cart.Subtotal * (1 - percent);
}
```

## 3. Small surface area

Fewer methods and fewer parameters mean fewer tests and simpler setup. Collapse a sprawling parameter list into a single intent-revealing argument.

```csharp
// GOOD — one parameter object, one method to exercise
public Reservation Book(BookingRequest request) { /* ... */ }

// BAD — six parameters, every test repeats the whole list
public Reservation Book(string guest, DateTime start, DateTime end,
    int roomType, bool breakfast, string promoCode) { /* ... */ }
```
