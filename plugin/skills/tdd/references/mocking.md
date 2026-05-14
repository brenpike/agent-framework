# When to Mock

## Mock at system boundaries only

OK to mock:
- External HTTP APIs (payment processors, email providers, third-party services)
- System clock / randomness (`DateTime.UtcNow`, `Guid.NewGuid()`)
- File system (when the test isn't about file I/O)
- Database — only when you can't use a test DB; prefer a real test DB

Do NOT mock:
- Your own classes, functions, modules
- Internal collaborators you control
- Anything you could use real

## Design for testability at boundaries

Use dependency injection so boundaries are easy to substitute:

```csharp
// Easy to test — inject the client
public string SendEmail(User user, string subject, string body, IEmailClient emailClient)
{
    return emailClient.Send(to: user.Email, subject: subject, body: body);
}

// Hard to test — creates its own client
public string SendEmail(User user, string subject, string body)
{
    var client = new SmtpClient(host: Settings.SmtpHost);
    return client.Send(to: user.Email, subject: subject, body: body);
}
```

In tests:
```csharp
[Fact]
public void SendEmailUsesUserAddress()
{
    var fakeClient = new FakeEmailClient();
    SendEmail(User(email: "a@b.com"), "Hi", "Hello", emailClient: fakeClient);
    Assert.Equal("a@b.com", fakeClient.LastRecipient);
}

// FakeEmailClient is a simple in-memory stub you control — not a Moq mock.
public class FakeEmailClient : IEmailClient
{
    public string LastRecipient { get; private set; }
    public string Send(string to, string subject, string body)
    {
        LastRecipient = to;
        return "sent";
    }
}
```

`FakeEmailClient` is a simple in-memory stub you control — not a `Moq` or `NSubstitute` mock. Real fakes are more robust than mocks because they enforce the contract of the interface.
