resource "aws_security_group" "ec2_sg" {
  name        = "${var.name_prefix}ec2_sql_server_sg"
  description = "Security group for EC2 SQL Server instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "RDP from VPC"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-ec2_sql_server_sg"
  }
}

resource "aws_secretsmanager_secret" "ec2_credentials" {
  name = "modern-engg-sqlserver"

  lifecycle {
    ignore_changes = [name]
  }
}

resource "random_password" "sa_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    ignore_changes = [result]
  }
}

resource "random_password" "netappuser_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    ignore_changes = [result]
  }
}

resource "aws_secretsmanager_secret_version" "ec2_credentials" {
  secret_id = aws_secretsmanager_secret.ec2_credentials.id
  secret_string = jsonencode({
    sa_username = "sa"
    sa_password = random_password.sa_password.result
    netappuser_username = "netappuser"
    netappuser_password = random_password.netappuser_password.result
    host = aws_instance.sql_server_instance.private_ip
  })

  lifecycle {
    ignore_changes =  [secret_string]
  }
}

# Add an IAM role for the EC2 instance
resource "aws_iam_role" "ec2_ssm_role" {
  name = "${var.name_prefix}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_instance_connect" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceConnect"
}

resource "aws_iam_role_policy_attachment" "secrets_manager_policy" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.vpc_private_subnets
  security_group_ids = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true
}
resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.vpc_private_subnets
  security_group_ids = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true
}
resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type = "Interface"
  subnet_ids        = var.vpc_private_subnets
  security_group_ids = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true
}

resource "aws_security_group" "vpc_endpoint_sg" {
  name        = "${var.name_prefix}-vpc-endpoint-sg"
  description = "Security group for VPC endpoints"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "vpc_endpoint_ingress" {
  type        = "ingress"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = [var.vpc_cidr]
  security_group_id = aws_security_group.vpc_endpoint_sg.id
}

resource "aws_security_group_rule" "allow_ec2_instance_connect" {
  type        = "ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["18.206.107.24/29"]  # EC2 Instance Connect IP range
  security_group_id = aws_security_group.ec2_sg.id
}

resource "aws_ssm_document" "session_manager_prefs" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Document to hold regional settings for Session Manager"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = true
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = true
      idleSessionTimeout          = "60"
      maxSessionDuration          = "120"
      kmsKeyId                    = ""
      runAsEnabled                = false
      shellProfile = {
        windows = "date"
      }
    }
  })
}

resource "aws_instance" "sql_server_instance" {
  ami           = "ami-0848f4d849e5b4667"
  instance_type = "t3a.xlarge"
  #subnet_id     = var.vpc_private_subnets[0]
  subnet_id     = length(var.vpc_private_subnets) > 0 ? var.vpc_private_subnets[0] : null


  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  key_name = var.key_name
  associate_public_ip_address = false

  user_data = <<-EOF
              <powershell>
              # Set Administrator password
              #  $password = (Get-SECSecretValue -SecretId ${aws_secretsmanager_secret.ec2_credentials.id}).SecretString | ConvertFrom-Json
              #  net user Administrator $password.password

              # Create a new user for RDP access
              #  $password = (Get-SECSecretValue -SecretId ${aws_secretsmanager_secret.ec2_credentials.id}).SecretString | ConvertFrom-Json
              #  New-LocalUser -Name "ec2-user" -Password ($password.password | ConvertTo-SecureString -AsPlainText -Force) -PasswordNeverExpires
              #  Add-LocalGroupMember -Group "Administrators" -Member "ec2-user"

              # Configure Windows Firewall
              New-NetFirewallRule -DisplayName "Allow SSM" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow
              New-NetFirewallRule -DisplayName "Allow RDP" -Direction Inbound -LocalPort 3389 -Protocol TCP -Action Allow

              # Enable RDP
              Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
              Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

              # Disable Network Level Authentication
              Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0

              # Installing AWS CLI
              $installer = "https://awscli.amazonaws.com/AWSCLIV2.msi"
              $logFile = "C:\Windows\Temp\awscli_install.log"
              Write-Output "Installing $($installer) ..."
              Start-Process -FilePath "C:\Windows\System32\msiexec.exe" -ArgumentList "/i $installer /passive /norestart /log `"$logFile`"" -Wait
              Write-Output "Done installing $($installer)"

              # Update SSM Agent
              $SSMAgentUrl = "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe"
              Start-Sleep -Seconds 60
              Invoke-WebRequest -Uri $SSMAgentUrl -OutFile "C:\AmazonSSMAgentSetup.exe"
              Start-Process -FilePath "C:\AmazonSSMAgentSetup.exe" -ArgumentList "/S" -Wait
              Restart-Service AmazonSSMAgent

              # Verify SSM Agent status
              Start-Sleep -Seconds 60
              $ssmagentService = Get-Service -Name "AmazonSSMAgent"
              if ($ssmagentService.Status -ne "Running") {
                  Write-Output "SSM Agent is not running. Attempting to start..."
                  Start-Service AmazonSSMAgent
                  Start-Sleep -Seconds 10
                  $ssmagentService.Refresh()
                  if ($ssmagentService.Status -ne "Running") {
                      Write-Output "Failed to start SSM Agent. Please check logs."
                  } else {
                      Write-Output "SSM Agent started successfully."
                  }
              } else {
                  Write-Output "SSM Agent is already running."
              }

              # Configure SSM Agent for debugging 
              #$SSMAgentConfigPath = "C:\ProgramData\Amazon\SSM\seelog.xml"
              #$SSMAgentConfig = Get-Content $SSMAgentConfigPath
              #$SSMAgentConfig = $SSMAgentConfig -replace '<seelog minlevel="info">', '<seelog minlevel="debug">'
              #Set-Content -Path $SSMAgentConfigPath -Value $SSMAgentConfig
              #Restart-Service AmazonSSMAgent

              # Install EC2 Instance Connect
              #$url = "https://s3.amazonaws.com/ec2-windows-ec2instanceconnect/EC2-Windows-EC2InstanceConnect.zip"
              #Start-Sleep -Seconds 60
              #Invoke-WebRequest -Uri $url -OutFile "C:\EC2-Windows-EC2InstanceConnect.zip"
              #Expand-Archive -Path "C:\EC2-Windows-EC2InstanceConnect.zip" -DestinationPath "C:\EC2-Windows-EC2InstanceConnect"
              #Start-Process -FilePath "C:\EC2-Windows-EC2InstanceConnect\install.ps1" -Wait

              # Install JRE
              $jreUrl = "https://javadl.oracle.com/webapps/download/AutoDL?BundleId=246474_2dee051a5d0647d5be72a7c0abff270e"
              Start-Sleep -Seconds 60
              Invoke-WebRequest -Uri $jreUrl -OutFile "C:\jre-installer.exe"
              Start-Process -FilePath "C:\jre-installer.exe" -ArgumentList "/s" -Wait

              # Install Babelfish Compass
              $babelfishReleaseUrl = "https://github.com/babelfish-for-postgresql/babelfish_compass/releases/latest"
              $latestRelease = Invoke-RestMethod -Uri $babelfishReleaseUrl
              $zipAsset = $latestRelease.assets | Where-Object { $_.name -match "^BabelfishCompass_[a-zA-Z0-9]+(-[a-zA-Z0-9]+)?\.zip$" } | Select-Object -First 1
              Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile "C:\BabelfishCompass.zip"
              Start-Sleep -Seconds 60
              Expand-Archive -Path "C:\BabelfishCompass.zip" -DestinationPath "C:\BabelfishCompass"

              # Retrieve the secret from AWS Secrets Manager
              $secret = Get-SECSecretValue -SecretId ${aws_secretsmanager_secret.ec2_credentials.id}

              # Parse the JSON content
              $secretData = $secret.SecretString | ConvertFrom-Json

              # Extract passwords from the secret
              $saPassword = $secretData.sa_password
              $netappuserPassword = $secretData.netappuser_password

              # Create Northwind database and configure users
              $sqlCommand = @"
              -- Check if Northwind database exists, if not create it
              IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'Northwind')
              BEGIN
                  CREATE DATABASE Northwind;
              END
              GO

              USE Northwind;
              GO

              -- Set password for 'sa' account
              ALTER LOGIN sa WITH PASSWORD = '$saPassword';
              GO

              -- Ensure 'sa' has sysadmin role
              IF IS_SRVROLEMEMBER('sysadmin', 'sa') = 0
              BEGIN
                  ALTER SERVER ROLE sysadmin ADD MEMBER sa;
              END
              GO

              -- Create login for application user if it doesn't exist
              IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'netappuser')
              BEGIN
                  CREATE LOGIN netappuser WITH PASSWORD = '$netappuserPassword';
              END
              GO

              -- Create user for the login in Northwind database
              IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'netappuser')
              BEGIN
                  CREATE USER netappuser FOR LOGIN netappuser;
              END
              GO

              -- Grant necessary permissions to netappuser
              GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO netappuser;
              GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION TO netappuser;
              GO

              -- Add netappuser to db_ddladmin role for creating triggers
              ALTER ROLE db_ddladmin ADD MEMBER netappuser;
              GO

              -- Output success message
              PRINT 'Northwind database setup completed successfully.';
              GO
            "@

              # Ensure sqlcmd is in the PATH or use the full path
              $env:Path += ";C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn"
              $sqlCommand | sqlcmd -S localhost 

              # Activate SSMS
              $ssmsPath = (Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\Ssms.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName

              if ($ssmsPath) {
                  Write-Output "SSMS found at: $ssmsPath. Attempting to activate..."
                  $process = Start-Process -FilePath $ssmsPath -ArgumentList "/initialize" -PassThru -WindowStyle Hidden
                  $process | Wait-Process -Timeout 300 -ErrorAction SilentlyContinue
                  if ($process.HasExited) {
                      Write-Output "SSMS activation process completed."
                  } else {
                      Write-Output "SSMS activation process timed out. It may still be running in the background."
                      $process | Stop-Process -Force
                  }
              } else {
                  Write-Output "SSMS not found. Please check the installation."
              }
             
              </powershell>
              EOF

    lifecycle {
    ignore_changes = [
      ami,
      user_data,
      tags
    ]
  }

tags = merge(
  #var.common_tags,
  {
    Name = "${var.name_prefix}-sql_server_instance"
  }
)

}
