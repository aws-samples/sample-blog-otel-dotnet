# .NET 10 (LTS). Base images pinned by tag + digest for reproducible builds.
FROM mcr.microsoft.com/dotnet/sdk:10.0.404@sha256:fe0fd4e93bd2fbb47c883b7a6369e5c8d3db8bf01cdc5981f6ee35fbdf3ff4fb AS build
WORKDIR /src
COPY *.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app --no-restore
# Fetch the Amazon RDS global CA bundle (public CA certs, official RDS truststore) so the
# runtime image can validate the RDS SQL Server certificate chain (Encrypt=true;
# TrustServerCertificate=false). Fetched at build time so no .pem is stored in the repo.
RUN curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /tmp/rds-global-bundle.pem

FROM mcr.microsoft.com/dotnet/aspnet:10.0.15@sha256:bfd912c83295ce66d4b706ebb8541b9f14259b0e76fbb88b2751f58ce2399d2e
WORKDIR /app
# update-ca-certificates only ingests *.crt files, so the PEM is copied with a .crt name.
COPY --from=build /tmp/rds-global-bundle.pem /usr/local/share/ca-certificates/aws-rds-global-bundle.crt
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /app .
EXPOSE 5000
ENV ASPNETCORE_URLS=http://+:5000
USER $APP_UID
ENTRYPOINT ["dotnet", "BackendApi.dll"]
