# Safe handling

<script>window.evil = true</script>
<img src="https://example.invalid/track" onerror="alert(1)">

![Remote](https://example.invalid/track.png)
![Outside](../../../../../etc/passwd)
![Encoded outside](%2e%2e/%2e%2e/private.png)
[Unsafe](javascript:alert(1))
[Local](file:///etc/passwd)
[Application](x-apple.systempreferences:com.apple.preference.security)

```html
<script>not executable</script>
```
