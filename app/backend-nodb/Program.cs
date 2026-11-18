// Backend API (NO DATABASE variant) — runs on port 5000.
// Identical HTTP surface to the SQL-backed backend, but stores orders in memory.
// Used for the trace demo where a database is out of scope: ADOT .NET
// auto-instrumentation still produces the incoming-HTTP server span (and the
// frontend's outgoing-HTTP client span), so the distributed frontend -> backend
// trace and the Application Signals service map appear exactly as in the full app.
//
// A small artificial delay + an internal Activity span are added so the X-Ray
// waterfall shows a meaningful backend segment instead of a sub-millisecond blip.

using System.Collections.Concurrent;
using System.Diagnostics;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://*:5000");
var app = builder.Build();

// ActivitySource lets us emit an explicit internal span inside each handler.
// ADOT auto-instrumentation also captures ASP.NET Core + HttpClient spans with no code.
var activitySource = new ActivitySource("OTelDemo.Backend");

// In-memory store (thread-safe), seeded to mirror the SQL version's seed data.
var orders = new ConcurrentDictionary<int, Order>();
var nextId = 0;
void Seed(string item, int qty, string status)
{
    var id = Interlocked.Increment(ref nextId);
    orders[id] = new Order(id, item, qty, status);
}
Seed("Widget A", 10, "shipped");
Seed("Widget B", 5, "processing");
Seed("Gadget C", 2, "pending");

app.MapGet("/api/health", () =>
    Results.Ok(new { status = "healthy", service = "backend-api", store = "in-memory", timestamp = DateTime.UtcNow }));

app.MapGet("/api/orders", async () =>
{
    using var span = activitySource.StartActivity("list-orders", ActivityKind.Internal);
    span?.SetTag("orders.count", orders.Count);
    await Task.Delay(Random.Shared.Next(15, 60)); // simulate work so the span has visible duration
    return Results.Ok(orders.Values.OrderBy(o => o.Id)
        .Select(o => new { id = o.Id, item = o.Item, qty = o.Qty, status = o.Status }));
});

app.MapGet("/api/orders/{id}", async (int id) =>
{
    using var span = activitySource.StartActivity("get-order", ActivityKind.Internal);
    span?.SetTag("order.id", id);
    await Task.Delay(Random.Shared.Next(10, 40));
    if (!orders.TryGetValue(id, out var o))
    {
        span?.SetStatus(ActivityStatusCode.Error, "not found");
        return Results.NotFound(new { error = $"Order {id} not found" });
    }
    return Results.Ok(new { id = o.Id, item = o.Item, qty = o.Qty, status = o.Status });
});

app.MapPost("/api/orders", async () =>
{
    using var span = activitySource.StartActivity("create-order", ActivityKind.Internal);
    await Task.Delay(Random.Shared.Next(20, 70));
    var id = Interlocked.Increment(ref nextId);
    var order = new Order(id, $"Order-{DateTime.UtcNow:HHmmss}", Random.Shared.Next(1, 20), "created");
    orders[id] = order;
    span?.SetTag("order.id", id);
    return Results.Created($"/api/orders/{id}", new { id, status = "created" });
});

app.Run();

record Order(int Id, string Item, int Qty, string Status);
