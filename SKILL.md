---
name: copilot-studio-migration
description: |
  Migrate a Microsoft Copilot Studio agent from the classic experience (topics-based) 
  to the new experience (instructions-based). Provide a classic agent URL and this skill 
  will extract, transform, and create the new agent via Dataverse API. When running in 
  Microsoft Scout (browser available), it also automates Workflow tool addition, 
  Connection authentication, and publishing via the Copilot Studio UI.
  Triggers: 'migrate agent', 'classic to new', 'copilot studio migration', 
  'エージェント移行', 'classic agent', 'new experience に移行'
---

# Copilot Studio Agent Migration Skill (Classic → New Experience)

## Overview

This skill migrates a Copilot Studio **classic** agent (topics/GenerativeAIRecognizer) 
to a **new experience** agent (instructions/CLICopilotRecognizer).

**Dual-mode operation:**
- **Microsoft Scout** (browser available): Full end-to-end automation including UI steps
- **GitHub Copilot** (no browser): API-only automation + manual step guidance

## Prerequisites

- Azure CLI (`az`) logged in with access to the target Dataverse environment
- The user must have Maker permissions in the target environment
- The classic agent URL (format: `https://copilotstudio.preview.microsoft.com/environments/{envId}/bots/{botId}`)
- For Scout: User must be signed into Copilot Studio in the browser

## Execution Flow

### Phase 1: API-Based Migration (Both Environments)

Run the migration script:
```powershell
pwsh -ExecutionPolicy Bypass -File "{skillDir}/migrate.ps1" -ClassicUrl "{url}" -OrgUrl "{orgUrl}"
```

To find the OrgUrl, use:
```powershell
pac env list | Select-String "{envId}"
```

The script will:
1. Parse URL → Extract envId + botId
2. Authenticate via `az account get-access-token`
3. Extract all bot components from Dataverse
4. Analyze and categorize components (topics, MCP tools, flows, knowledge)
5. Build new instructions (converting Adaptive Cards to conversational flows)
6. Create new agent with `cliagent-1.0.0` template
7. Register MCP tools as botcomponents
8. Output the new agent URL and remaining manual steps

### Phase 2: Browser Automation (Scout Only)

**IMPORTANT: Only execute Phase 2 if you have browser access (Microsoft Scout).
If running in GitHub Copilot, skip to Phase 3.**

After Phase 1 completes, use browser automation to complete the remaining steps:

#### Step 2a: Open the New Agent

```
Navigate to: https://copilotstudio.preview.microsoft.com/environments/{envId}/agents/{newBotId}
Wait for the Build tab to load.
```

#### Step 2b: Add Workflow Tool

The Phase 1 output includes any Power Automate flows that need to be added as Workflow tools.
For each workflow:

1. **Click "Add a tool"** button on the Build page
   - Look for button with text "Add a tool" or "ツールを追加" or the + icon in the Tools section
   
2. **Select "Workflow"** from the tool type options
   - In the tool picker dialog, select "Workflow" / "ワークフロー"
   
3. **Search for the flow** by name
   - Type the flow name (e.g., "STU_新規質問起票フロー") in the search box
   - Wait for results to load
   
4. **Select the flow** from results
   - Click on the matching flow item
   
5. **Confirm addition**
   - Click "Add" / "追加" button to confirm

6. **Verify** the tool appears in the Tools list on the Build page

#### Step 2c: Configure Connections

After adding tools, connections may need authentication:

1. **Check for connection warnings** - Look for warning icons or "Configure" buttons next to tools
   
2. For each tool needing configuration:
   - Click "Configure" on the tool
   - If a sign-in prompt appears, click "Sign in"
   - Wait for the OAuth flow to complete (the browser may redirect)
   - Verify the connection shows as "Connected"

3. **If no warnings appear**, connections are already configured (this is common when the same connectors are used in other agents in the environment)

#### Step 2d: Test in Preview

1. Click the **"Preview"** tab
2. Send a test message: "ASK PPSEについて教えて"
3. Verify the agent responds with knowledge-based answer
4. Send: "エスカレーション"
5. Verify the agent starts asking for escalation information conversationally
6. Report test results to user

#### Step 2e: Publish (Optional - Ask User First)

Before publishing, ASK the user if they want to publish:
> "テストが完了しました。エージェントを公開しますか？"

If yes:
1. Click **"Publish"** button (top right area)
2. Confirm in the publish dialog
3. Wait for publish to complete
4. Report success

### Phase 3: Output (GitHub Copilot Fallback)

**If running in GitHub Copilot (no browser access)**, output the following after Phase 1:

```
✅ API ベースの移行が完了しました:
- Agent: {name}
- URL: {agentUrl}
- Tools: {toolCount} MCP tools

⚠️ 以下のステップはブラウザ操作が必要なため、手動で行ってください:
（Microsoft Scout で実行すると自動化できます）

1. Copilot Studio を開く: {agentUrl}
2. "Add a tool" → "Workflow" → "{flowName}" を追加
   Flow ID: {flowId}
3. 各 Tool の Connection を認証 (Configure → Sign in)
4. Preview タブでテスト
5. Publish

💡 ヒント: このスキルを Microsoft Scout で実行すると、上記のステップも
   すべて自動で実行されます。
```

## Component Analysis Reference

### Classic → New Mapping

| Classic Kind | Classic Role | New Equivalent |
|---|---|---|
| `AdaptiveDialog` (OnRecognizedIntent) | Custom Topic | Instructions segment or Skill |
| `AdaptiveDialog` (OnUnknownIntent) | Fallback/Search | Drop (orchestrator handles) |
| `AdaptiveDialog` (OnConversationStart) | Greeting | Instructions |
| `AdaptiveDialog` (OnPlanComplete) | Post-response | Instructions |
| `TaskDialog` + MCP metadata | MCP Tool | `McpTool` component |
| `TaskDialog` + InvokeFlowTaskAction | Power Automate | Workflow (via UI/Scout) |
| `TaskDialog` + InvokeConnectorTaskAction | Connector | Tool (via UI/Scout) |
| `GptComponentMetadata` (type 15) | GPT Config | `agentSettings.instructions` |
| `KnowledgeSourceConfiguration` (type 16) | Knowledge | Dataverse MCP Tool |

### Adaptive Card Conversion

**Input forms (AdaptiveCardPrompt)** → Conversational collection in instructions:
- Extract all Input fields from the card JSON
- List them as required information to collect
- Add "ask one by one, confirm before execution" guidance

**Action buttons (messageBack)** → Text-based triggers in instructions:
- Extract the messageBack text
- Add as a trigger condition in instructions

## Error Handling

- `az account get-access-token` fails → User needs `az login --tenant {tenantId}`
- Bot creation 403 → User lacks Maker role
- Component 400 → Schema name issue (ensure ASCII-only, max 100 chars)
- `pac copilot extract-template` crashes → Known bug with newer knowledge types, use direct API
- Browser: "Add a tool" button not found → Page may still be loading, wait and retry
- Browser: Connection auth redirect → Wait for redirect to complete, verify status

## File Reference

- `SKILL.md` - This file (skill definition and instructions)
- `migrate.ps1` - PowerShell migration script (Phase 1 automation)
