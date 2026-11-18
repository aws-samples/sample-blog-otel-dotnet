// Frontend — runs on IIS (port 80) on the frontend EC2 instance.
// Serves HTML pages and proxies API calls to the backend instance.
// The BACKEND_URL env var is set by the setup script to point at the backend private IP.

var builder = WebApplication.CreateBuilder(args);
var backendUrl = Environment.GetEnvironmentVariable("BACKEND_URL") ?? "http://localhost:5000";
builder.Services.AddHttpClient("backend", c => c.BaseAddress = new Uri(backendUrl));
var app = builder.Build();

app.MapGet("/", () => Results.Content(HomePage(), "text/html"));

app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "frontend", backend = backendUrl, timestamp = DateTime.UtcNow }));

// Proxy to backend — these calls will show as distributed traces
app.MapGet("/api/{**path}", async (string path, IHttpClientFactory factory) =>
{
    var client = factory.CreateClient("backend");
    var resp = await client.GetAsync($"/api/{path}");
    var body = await resp.Content.ReadAsStringAsync();
    return Results.Content(body, "application/json", statusCode: (int)resp.StatusCode);
});

app.MapPost("/api/{**path}", async (string path, IHttpClientFactory factory) =>
{
    var client = factory.CreateClient("backend");
    var resp = await client.PostAsync($"/api/{path}", null);
    var body = await resp.Content.ReadAsStringAsync();
    return Results.Content(body, "application/json", statusCode: (int)resp.StatusCode);
});

app.Run();

static string HomePage() => """
<!DOCTYPE html>
<html><head><title>OTel Demo - Order Dashboard</title>
<style>
  body { font-family: system-ui; max-width: 800px; margin: 40px auto; padding: 0 20px; }
  button { padding: 8px 16px; margin: 4px; cursor: pointer; }
  pre { background: #f4f4f4; padding: 16px; border-radius: 4px; overflow-x: auto; }
  .header { border-bottom: 2px solid #232f3e; padding-bottom: 10px; }
  .actions { margin: 20px 0; }
</style></head>
<body>
  <div class="header">
    <h1>📦 Order Dashboard</h1>
    <p>Frontend → Backend distributed tracing demo</p>
  </div>
  <div class="actions">
    <button onclick="call('/api/orders')">List Orders</button>
    <button onclick="call('/api/orders/1')">Get Order #1</button>
    <button onclick="call('/api/orders/999')">Get Order #999 (404)</button>
    <button onclick="callPost('/api/orders')">Create Order</button>
    <button onclick="call('/api/health')">Backend Health</button>
    <button onclick="loadTest()">🔥 Load Test (20 requests)</button>
  </div>
  <h3>Response</h3>
  <pre id="out">Click a button above...</pre>
  <script>
    async function call(path) {
      const el = document.getElementById('out');
      el.textContent = 'Loading...';
      const r = await fetch(path);
      el.textContent = `${r.status} ${r.statusText}\n\n` + JSON.stringify(await r.json(), null, 2);
    }
    async function callPost(path) {
      const el = document.getElementById('out');
      el.textContent = 'Loading...';
      const r = await fetch(path, {method:'POST'});
      el.textContent = `${r.status} ${r.statusText}\n\n` + JSON.stringify(await r.json(), null, 2);
    }
    async function loadTest() {
      const el = document.getElementById('out');
      el.textContent = 'Running 20 requests...';
      const paths = ['/api/orders','/api/orders/1','/api/orders/2','/api/orders/999'];
      const results = await Promise.all(
        Array.from({length:20}, (_,i) => fetch(paths[i%paths.length]).then(r => `${r.status}`))
      );
      el.textContent = `Done! Results: ${results.join(', ')}`;
    }
  </script>
</body></html>
""";
