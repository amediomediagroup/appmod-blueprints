# 1 - Build Angular App
FROM node:18 as node

WORKDIR /app

COPY WebUI/ClientApp/package*.json ./

RUN npm install

COPY WebUI/ClientApp/*.* ./
COPY WebUI/ClientApp/src ./src

RUN npm run build

# 2 - Build .NET 6 Web App
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /app

COPY . .

WORKDIR /app/WebUI
RUN dotnet restore

RUN dotnet publish -c Release -o out

# 3 - Runtime
FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS runtime
WORKDIR /app

COPY --from=node /app/dist ./ClientApp/dist/
COPY --from=build /app/WebUI/out ./

ENTRYPOINT ["dotnet", "Northwind.WebUI.dll"]
