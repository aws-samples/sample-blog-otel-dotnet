// Backend API — runs on port 5000 on the backend EC2 instance.
// Uses SQL Server for order storage. ADOT auto-instruments SqlClient
// producing spans with db.system, db.name, db.statement, and duration.

using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://*:5000");
var app = builder.Build();

var connStr = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING")
    ?? throw new InvalidOperationException(
        "DB_CONNECTION_STRING is not set. It is injected as a machine-scope environment " +
        "variable with credentials resolved from Secrets Manager at deploy time. " +
        "No credentials are hardcoded in source.");

// --- Auto-migration: create OrdersDb + Orders table + seed data if missing ---
// This lets the ECS deployment be self-contained (no separate DB setup step needed),
// mirroring the intent of the EC2 create-db.ps1 script but run on container startup.
await EnsureDatabaseAsync(connStr);

app.MapGet("/api/health", () => Results.Ok(new { status = "healthy", service = "backend-api", timestamp = DateTime.UtcNow }));

app.MapGet("/api/orders", async () =>
{
    await using var conn = new SqlConnection(connStr);
    await conn.OpenAsync();
    await using var cmd = new SqlCommand("SELECT Id, Item, Qty, Status FROM Orders", conn);
    await using var reader = await cmd.ExecuteReaderAsync();
    var orders = new List<object>();
    while (await reader.ReadAsync())
        orders.Add(new { id = reader.GetInt32(0), item = reader.GetString(1), qty = reader.GetInt32(2), status = reader.GetString(3) });
    return Results.Ok(orders);
});

app.MapGet("/api/orders/{id}", async (int id) =>
{
    await using var conn = new SqlConnection(connStr);
    await conn.OpenAsync();
    await using var cmd = new SqlCommand("SELECT Id, Item, Qty, Status FROM Orders WHERE Id = @Id", conn);
    cmd.Parameters.AddWithValue("@Id", id);
    await using var reader = await cmd.ExecuteReaderAsync();
    if (!await reader.ReadAsync())
        return Results.NotFound(new { error = $"Order {id} not found" });
    return Results.Ok(new { id = reader.GetInt32(0), item = reader.GetString(1), qty = reader.GetInt32(2), status = reader.GetString(3) });
});

app.MapPost("/api/orders", async () =>
{
    await using var conn = new SqlConnection(connStr);
    await conn.OpenAsync();
    await using var cmd = new SqlCommand(
        "INSERT INTO Orders (Item, Qty, Status) OUTPUT INSERTED.Id VALUES (@Item, @Qty, @Status)", conn);
    cmd.Parameters.AddWithValue("@Item", $"Order-{DateTime.UtcNow:HHmmss}");
    cmd.Parameters.AddWithValue("@Qty", Random.Shared.Next(1, 20));
    cmd.Parameters.AddWithValue("@Status", "created");
    var newId = (int)await cmd.ExecuteScalarAsync()!;
    return Results.Created($"/api/orders/{newId}", new { id = newId, status = "created" });
});

app.Run();

static async Task EnsureDatabaseAsync(string dbConnStr)
{
    // Build a connection string to "master" by swapping out the Database segment.
    var masterConnStr = System.Text.RegularExpressions.Regex.Replace(
        dbConnStr, @"Database=[^;]+;", "Database=master;", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    const int maxAttempts = 10;
    for (var attempt = 1; attempt <= maxAttempts; attempt++)
    {
        try
        {
            await using var masterConn = new SqlConnection(masterConnStr);
            await masterConn.OpenAsync();
            await using var createDbCmd = new SqlCommand("IF DB_ID('OrdersDb') IS NULL CREATE DATABASE OrdersDb;", masterConn);
            await createDbCmd.ExecuteNonQueryAsync();
            break;
        }
        catch (Exception ex) when (attempt < maxAttempts)
        {
            Console.WriteLine($"[EnsureDatabaseAsync] Attempt {attempt}/{maxAttempts} failed to reach SQL Server: {ex.Message}. Retrying in 5s...");
            await Task.Delay(5000);
        }
    }

    await using var conn = new SqlConnection(dbConnStr);
    await conn.OpenAsync();

    await using var createTableCmd = new SqlCommand(@"
        IF OBJECT_ID('Orders','U') IS NULL
        CREATE TABLE Orders (
            Id INT IDENTITY(1,1) PRIMARY KEY,
            Item NVARCHAR(100) NOT NULL,
            Qty INT NOT NULL,
            Status NVARCHAR(50) NOT NULL
        );", conn);
    await createTableCmd.ExecuteNonQueryAsync();

    await using var seedCmd = new SqlCommand(@"
        IF NOT EXISTS (SELECT 1 FROM Orders)
        BEGIN
            INSERT INTO Orders (Item, Qty, Status) VALUES ('Widget A', 10, 'shipped');
            INSERT INTO Orders (Item, Qty, Status) VALUES ('Widget B', 5, 'processing');
            INSERT INTO Orders (Item, Qty, Status) VALUES ('Gadget C', 2, 'pending');
        END", conn);
    await seedCmd.ExecuteNonQueryAsync();

    Console.WriteLine("[EnsureDatabaseAsync] OrdersDb ready (database, table, seed data verified).");
}
