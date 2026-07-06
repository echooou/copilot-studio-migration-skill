<#
.SYNOPSIS
    Copilot Studio Classic → New Experience Migration Script
.DESCRIPTION
    Extracts a classic agent's configuration and creates a new experience agent.
    Run this from GitHub Copilot chat or standalone.
.PARAMETER ClassicUrl
    The Copilot Studio URL of the classic agent
.PARAMETER OrgUrl
    The Dataverse org URL (e.g., https://orgXXX.crm7.dynamics.com)
.EXAMPLE
    .\migrate.ps1 -ClassicUrl "https://copilotstudio.preview.microsoft.com/environments/xxx/bots/yyy" -OrgUrl "https://orgXXX.crm7.dynamics.com"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ClassicUrl,
    
    [Parameter(Mandatory=$true)]
    [string]$OrgUrl
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -ErrorAction SilentlyContinue
$ErrorActionPreference = "Stop"

#region --- Parse URL ---
if ($ClassicUrl -match "environments/([a-f0-9-]+)/bots/([a-f0-9-]+)") {
    $envId = $Matches[1]
    $botId = $Matches[2]
    Write-Host "Environment: $envId"
    Write-Host "Bot ID: $botId"
} else {
    throw "Invalid classic agent URL format. Expected: .../environments/{envId}/bots/{botId}"
}
#endregion

#region --- Authenticate ---
Write-Host "`n[1/7] Authenticating..."
$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if (-not $token) { throw "Failed to get token. Run: az login --tenant <your-tenant>" }
$headers = @{
    Authorization = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version" = "4.0"
    Accept = "application/json"
    "Content-Type" = "application/json; charset=utf-8"
}
$baseUrl = "$OrgUrl/api/data/v9.2"
Write-Host "  Authenticated successfully"
#endregion

#region --- Extract Classic Agent ---
Write-Host "`n[2/7] Extracting classic agent..."
$bot = Invoke-RestMethod -Uri "$baseUrl/bots($botId)" -Headers $headers
Write-Host "  Name: $($bot.name)"
Write-Host "  Language: $($bot.language)"
Write-Host "  Template: $($bot.template)"

$components = Invoke-RestMethod -Uri "$baseUrl/botcomponents?`$filter=_parentbotid_value eq '$botId'&`$select=name,componenttype,data,schemaname" -Headers $headers
Write-Host "  Components: $($components.value.Count)"
#endregion

#region --- Analyze Components ---
Write-Host "`n[3/7] Analyzing components..."

$gptConfig = $components.value | Where-Object { $_.componenttype -eq 15 }
$knowledgeSources = $components.value | Where-Object { $_.componenttype -eq 16 }
$topics = $components.value | Where-Object { $_.componenttype -eq 9 }

# Categorize topics by kind
$mcpTools = @()
$flowActions = @()
$connectorActions = @()
$customTopics = @()
$systemTopics = @()

foreach ($topic in $topics) {
    $data = $topic.data
    if ($data -match "kind:\s*TaskDialog") {
        if ($data -match "ModelContextProtocolMetadata") {
            $mcpTools += $topic
        } elseif ($data -match "InvokeFlowTaskAction") {
            $flowActions += $topic
        } elseif ($data -match "InvokeConnectorTaskAction") {
            $connectorActions += $topic
        } else {
            $flowActions += $topic  # Treat as flow by default
        }
    } elseif ($data -match "kind:\s*AdaptiveDialog") {
        if ($data -match "OnConversationStart|OnUnknownIntent|OnPlanComplete") {
            $systemTopics += $topic
        } else {
            # Check if it's a system topic by schema name
            $sysPatterns = "Greeting|EndofConversation|StartOver|Fallback|OnError|Goodbye|ResetConversation|Signin|Escalate|MultipleTopicsMatched|ThankYou|Search|EPW"
            if ($topic.schemaname -match $sysPatterns) {
                $systemTopics += $topic
            } else {
                $customTopics += $topic
            }
        }
    }
}

Write-Host "  MCP Tools: $($mcpTools.Count)"
Write-Host "  Power Automate Flows: $($flowActions.Count)"
Write-Host "  Connector Actions: $($connectorActions.Count)"
Write-Host "  Custom Topics: $($customTopics.Count)"
Write-Host "  System Topics (will skip): $($systemTopics.Count)"
Write-Host "  Knowledge Sources: $($knowledgeSources.Count)"
#endregion

#region --- Build Instructions ---
Write-Host "`n[4/7] Building instructions..."

# Start with GPT config instructions
$baseInstructions = ""
if ($gptConfig) {
    $gptData = $gptConfig.data
    if ($gptData -match "(?s)instructions:\s*\|?\+?\s*\n(.*?)(?=\n\w+:|\z)") {
        $baseInstructions = $Matches[1] -replace "(?m)^  ", ""
    }
}

# Replace topic display name references
$baseInstructions = [regex]::Replace($baseInstructions, "\{System\.Bot\.Components\.Topics\.'([^']+)'\.DisplayName\}", {
    param($m)
    $schema = $m.Groups[1].Value
    $comp = $components.value | Where-Object { $_.schemaname -eq $schema }
    if ($comp) { $comp.name } else { $schema }
})

# Add escalation/flow instructions for AdaptiveCardPrompt topics
foreach ($topic in $customTopics) {
    $data = $topic.data
    if ($data -match "AdaptiveCardPrompt") {
        # Extract card JSON to find input fields
        $fields = @()
        if ($data -match '"id":\s*"(Input\w+)"') {
            $inputMatches = [regex]::Matches($data, '"id":\s*"(Input\w+)"')
            foreach ($im in $inputMatches) { $fields += $im.Groups[1].Value }
        }
        
        # Extract choices if any
        $choices = @()
        $choiceMatches = [regex]::Matches($data, '"title":\s*"([^"]+)",\s*"value":\s*"([^"]+)"')
        foreach ($cm in $choiceMatches) { $choices += $cm.Groups[1].Value }
        
        # Extract model description
        $desc = ""
        if ($data -match "modelDescription:\s*(.+)") { $desc = $Matches[1].Trim() }
        
        $baseInstructions += "`n`n## $($topic.name) フロー`n"
        $baseInstructions += "$desc`n"
        $baseInstructions += "以下の情報を対話的に収集してください：`n"
        foreach ($f in $fields) {
            $label = $f -replace "^Input", ""
            $baseInstructions += "- **$label**`n"
        }
        if ($choices.Count -gt 0) {
            $baseInstructions += "製品の選択肢: $($choices -join ', ')`n"
        }
        $baseInstructions += "`n収集方法：自然な対話で1つずつ確認し、全情報が揃ったら内容を表示してユーザーの承認を得てください。`n"
        $baseInstructions += "承認後、ワークフローを呼び出して実行してください。`n"
    }
}

# Add Dataverse knowledge source details to instructions
# Classic uses Knowledge Source (type 16) → New uses Dataverse MCP Tool
# Extract table/column info from knowledge config and existing instructions
if ($knowledgeSources.Count -gt 0) {
    $knowledgeDetails = @()
    foreach ($ks in $knowledgeSources) {
        $ksData = $ks.data
        $ksKind = ""
        $ksConfig = ""
        if ($ksData -match "kind:\s*(\w+)") { $ksKind = $Matches[1] }
        if ($ksData -match "skillConfiguration:\s*(\S+)") { $ksConfig = $Matches[1] }
        $knowledgeDetails += @{ name = $ks.name; kind = $ksKind; config = $ksConfig }
    }
    
    # Also extract Dataverse table info from MCP tool definitions (if present)
    $dvMcpTools = $mcpTools | Where-Object { $_.data -match "commondataserviceforapps|InvokeMCP" }
    
    # Check if instructions already mention Dataverse/knowledge table usage
    if ($baseInstructions -notmatch "Dataverse MCP") {
        $baseInstructions += "`n`n## Dataverse MCP ツール利用ガイド`n"
        $baseInstructions += "Dataverse MCP Tool を使用してナレッジを検索します。`n"
        foreach ($kd in $knowledgeDetails) {
            if ($kd.kind -eq "DataverseStructuredSearchSource") {
                $baseInstructions += "- ナレッジソース: $($kd.name) (Dataverse テーブル検索)`n"
                $baseInstructions += "  - Dataverse MCP の list_records や search を使用してデータを取得`n"
                $baseInstructions += "  - 検索キーワードに基づいて関連レコードを返す`n"
            }
        }
    }
}

# Extract Dataverse table/column details from existing GPT instructions
# If the original instructions reference specific tables/columns, preserve that context
$dvTablePattern = "(?i)(table|テーブル)[^:：]*[:：]\s*(\w+)"
$dvColumnPattern = "(?i)(column|列|カラム)[^:：]*[:：]\s*(\w+)"
if ($baseInstructions -match $dvTablePattern) {
    Write-Host "  Dataverse table reference found in instructions"
}

Write-Host "  Instructions length: $($baseInstructions.Length) chars"
#endregion

#region --- Create New Agent ---
Write-Host "`n[5/7] Creating new agent..."

$configObj = @{
    '$kind' = "BotConfiguration"
    channels = @(
        @{ '$kind' = "ChannelDefinition"; id = "MsTeams"; channelId = "MsTeams" }
    )
    recognizer = @{ '$kind' = "CLICopilotRecognizer" }
    agentSettings = @{
        '$kind' = "AgentSettings"
        model = @{ '$kind' = "ModelConfig"; series = "Sonnet46" }
        instructions = @{
            '$kind' = "Instructions"
            segments = @(
                @{ '$kind' = "StaticSegment"; value = $baseInstructions }
            )
        }
    }
}
$configJson = $configObj | ConvertTo-Json -Depth 10 -Compress

$botBody = @{
    name = "$($bot.name) (migrated)"
    language = $bot.language
    template = "cliagent-1.0.0"
    configuration = $configJson
    accesscontrolpolicy = 0
    authenticationmode = 2
    authenticationtrigger = 1
} | ConvertTo-Json -Depth 10

$response = Invoke-WebRequest -Uri "$baseUrl/bots" -Headers $headers -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($botBody)) -UseBasicParsing
$newBotId = ""
# OData-EntityId header contains the new record URL
$entityId = $response.Headers["OData-EntityId"]
if ($entityId -is [array]) { $entityId = $entityId[0] }
if ($entityId -match '\(([a-f0-9-]+)\)') {
    $newBotId = $Matches[1]
} else {
    # Fallback: query by name
    $newName = "$($bot.name) (migrated)"
    $found = Invoke-RestMethod -Uri "$baseUrl/bots?`$filter=name eq '$newName'&`$select=botid&`$top=1&`$orderby=createdon desc" -Headers $headers
    if ($found.value.Count -gt 0) { $newBotId = $found.value[0].botid }
}
if (-not $newBotId) { throw "Failed to get new bot ID" }
Write-Host "  Created: $newBotId"
#endregion

#region --- Add MCP Tools ---
Write-Host "`n[6/7] Adding MCP tools..."

$toolCount = 0
$suffix = (Get-Random -Maximum 999).ToString("000")

foreach ($tool in $mcpTools) {
    $data = $tool.data
    $connectorId = ""
    $operationId = ""
    
    # Extract connector from connectionReference name
    if ($data -match "connectionReference:\s*\S+\.(shared_\w+)\.") {
        $connName = $Matches[1]
        $connectorId = "/providers/Microsoft.PowerApps/apis/$connName"
    }
    if ($data -match "operationId:\s*(\S+)") {
        $operationId = $Matches[1]
    }
    
    if ($connectorId -and $operationId) {
        # Schema name must be ASCII alphanumeric + underscores only
        $safeName = ($tool.name -replace '[^a-zA-Z0-9]','') 
        if ($safeName.Length -gt 40) { $safeName = $safeName.Substring(0,40) }
        $toolSchema = "cr_migrated_tool_$($safeName)_$suffix"
        $toolData = "kind: McpTool`nauthMode: Invoker`nconnectorId: $connectorId`noperationId: $operationId"
        
        $toolBody = @{
            name = $tool.name
            schemaname = $toolSchema
            componenttype = 9
            data = $toolData
            "parentbotid@odata.bind" = "/bots($newBotId)"
        } | ConvertTo-Json -Depth 5
        
        try {
            Invoke-WebRequest -Uri "$baseUrl/botcomponents" -Headers $headers -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($toolBody)) -UseBasicParsing | Out-Null
            Write-Host "  + $($tool.name)"
            $toolCount++
        } catch {
            Write-Host "  ! Failed: $($tool.name) - $($_.Exception.Message)"
        }
    }
}

# Add Dataverse MCP for knowledge sources
if ($knowledgeSources.Count -gt 0) {
    $toolSchema = "cr_migrated_tool_DataverseMCP_$suffix"
    $toolData = "kind: McpTool`nauthMode: Invoker`nconnectorId: /providers/Microsoft.PowerApps/apis/shared_commondataserviceforapps`noperationId: InvokeMCP"
    $toolBody = @{
        name = "Microsoft Dataverse - Microsoft Dataverse MCP"
        schemaname = $toolSchema
        componenttype = 9
        data = $toolData
        "parentbotid@odata.bind" = "/bots($newBotId)"
    } | ConvertTo-Json -Depth 5
    
    try {
        Invoke-WebRequest -Uri "$baseUrl/botcomponents" -Headers $headers -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($toolBody)) -UseBasicParsing | Out-Null
        Write-Host "  + Dataverse MCP (for knowledge)"
        $toolCount++
    } catch {
        Write-Host "  ! Failed: Dataverse MCP - $($_.Exception.Message)"
    }
}

Write-Host "  Total tools added: $toolCount"
#endregion

#region --- Output Summary ---
Write-Host "`n[7/7] Migration complete!"
Write-Host ("=" * 60)

$agentUrl = "https://copilotstudio.preview.microsoft.com/environments/$envId/agents/$newBotId"
Write-Host "`n✅ 自動移行完了:"
Write-Host "  Agent: $($bot.name) (migrated)"
Write-Host "  Bot ID: $newBotId"
Write-Host "  URL: $agentUrl"
Write-Host "  Tools: $toolCount MCP tools"

Write-Host "`n📋 手動対応が必要なステップ:"
Write-Host "  1. 上記 URL を開き Build タブを確認"
Write-Host "  2. 各 Tool の Connection を認証 (Configure → Sign in)"

if ($flowActions.Count -gt 0) {
    Write-Host "  3. Workflow の追加:"
    foreach ($fa in $flowActions) {
        $flowId = ""
        if ($fa.data -match "flowId:\s*([a-f0-9-]+)") { $flowId = $Matches[1] }
        Write-Host "     - 'Add a tool' → 'Workflow' → '$($fa.name)'"
        if ($flowId) { Write-Host "       Flow ID: $flowId" }
    }
}

if ($connectorActions.Count -gt 0) {
    Write-Host "  4. Connector Tool の追加:"
    foreach ($ca in $connectorActions) {
        Write-Host "     - 'Add a tool' → '$($ca.name)'"
    }
}

Write-Host "  Preview タブでテスト後、Publish してください。"
Write-Host ""
#endregion
