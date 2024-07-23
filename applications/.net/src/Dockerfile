# 1 - Build Angular App
FROM node:18 as node

WORKDIR /app

COPY Src/WebUI/ClientApp/package*.json ./

RUN npm install

COPY Src/WebUI/ClientApp/*.* ./
COPY Src/WebUI/ClientApp/src ./src

RUN npm run build

# 2 - Build .NET 6 Web App
FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /app

COPY *.sln .
COPY Src Src

WORKDIR /app/Src/WebUI
RUN dotnet restore

RUN dotnet publish -c Release -o out

# 3 - Runtime
FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS runtime
WORKDIR /app

COPY --from=node /app/dist ./ClientApp/dist/
COPY --from=build /app/Src/WebUI/out ./

ENTRYPOINT ["dotnet", "Northwind.WebUI.dll"]
