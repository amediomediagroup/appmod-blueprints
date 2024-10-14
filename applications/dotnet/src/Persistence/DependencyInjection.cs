using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Northwind.Application.Common.Interfaces;

namespace Northwind.Persistence
{
    public static class DependencyInjection
    {
        public static IServiceCollection AddPersistence(this IServiceCollection services, IConfiguration configuration)
        {
            var configurationbuilder = new ConfigurationBuilder()
                .AddJsonFile("appsettings.json")
                .AddJsonFile($"appsettings.Local.json", optional: true)
                .AddKeyPerFile("/opt/secret-volume", optional: true, reloadOnChange: true)
                .AddEnvironmentVariables()
                .Build();



            var connectionString = configuration.GetConnectionString("NorthwindDatabase");
            if (string.IsNullOrEmpty(connectionString))
            {
                connectionString = @"Server=" + configurationbuilder["dbendpoint"] + ";Database=NorthwindTraders;Persist Security Info = True; User Id=" + configurationbuilder["dbusername"] + "; Password = "
                + configurationbuilder["dbpassword"] + ";";
            }
            services.AddDbContext<NorthwindDbContext>(options =>
                options.UseSqlServer(connectionString));

            services.AddScoped<INorthwindDbContext>(provider => provider.GetService<NorthwindDbContext>());

            return services;
        }
    }
}
