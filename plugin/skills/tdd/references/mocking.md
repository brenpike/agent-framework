# When to Mock

## Mock at system boundaries only

OK to mock:
- External HTTP APIs (payment processors, email providers, third-party services)
- System clock / randomness (`datetime.now()`, `uuid4()`)
- File system (when the test isn't about file I/O)
- Database — only when you can't use a test DB; prefer a real test DB

Do NOT mock:
- Your own classes, functions, modules
- Internal collaborators you control
- Anything you could use real

## Design for testability at boundaries

Use dependency injection so boundaries are easy to substitute:

```python
# Easy to test — inject the client
def send_email(user, subject, body, *, email_client):
    return email_client.send(to=user.email, subject=subject, body=body)

# Hard to test — creates its own client
def send_email(user, subject, body):
    client = SmtpClient(host=settings.SMTP_HOST)
    return client.send(to=user.email, subject=subject, body=body)
```

In tests:
```python
def test_send_email_uses_user_address():
    fake_client = FakeEmailClient()
    send_email(user(email="a@b.com"), "Hi", "Hello", email_client=fake_client)
    assert fake_client.last_recipient == "a@b.com"
```

`FakeEmailClient` is a simple in-memory stub you control — not a `unittest.mock`. Real fakes are more robust than mocks because they enforce the contract of the interface.
