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

#### Step 2c: Add Connector Tools

For each Connector action identified in Phase 1 (e.g., Microsoft Teams):

1. Click **"Add a tool"** on the Build page
2. Search for the connector name (e.g., "Microsoft Teams")
3. Select the specific operation (e.g., "Post message to conversation")
4. Configure any required parameters
5. Click **"Add"** to confirm

#### Step 2d: Add Connected Agents (子エージェント)

If the Classic agent had agent-to-agent connections (InvokeExternalAgentTaskAction without MCP):

1. Find the **"Connected agents"** section on the Build page
2. Click **"Add"** or **"接続済みエージェントを追加"**
3. Search for the agent by name
4. Select and add
5. Verify it appears in the Connected agents list

Note: Fabric/Foundry Data Agents may not appear in this list. If not found, report to user.

#### Step 2e: Add Knowledge Sources (SharePoint, URL, Files)

If the Classic agent had knowledge sources beyond Dataverse:

1. Find the **"Knowledge"** section on the Build page
2. Click **"Add knowledge"** or **"ナレッジを追加"**
3. For **SharePoint**: Select "SharePoint" → Enter the site/library URL
4. For **URLs**: Select "Website" → Enter the URL
5. For **Files**: Select "Files" → Upload the files
6. Verify knowledge sources appear in the list

#### Step 2f: Enable Code Interpreter

If the Classic agent had Code Interpreter enabled (`codeInterpreter: true` in GPT config):

1. Look for a **Code Interpreter** toggle or setting in the Build page
2. Enable it
3. Verify it's active

#### Step 2g: Add AI Builder Prompts as Tools

If the Classic agent had AI Builder prompt nodes:

1. Click **"Add a tool"** on the Build page
2. Search for the prompt name or select "AI Builder" category
3. Copy the original prompt text from Phase 1 output
4. Configure the tool with the prompt content
5. Set model and input/output parameters manually
6. Save

#### Step 2h: Configure Connections

After adding tools, connections may need authentication:

1. **Check for connection warnings** - Look for warning icons or "Configure" buttons next to tools
   
2. For each tool needing configuration:
   - Click "Configure" on the tool
   - If a sign-in prompt appears, click "Sign in"
   - Wait for the OAuth flow to complete (the browser may redirect)
   - Verify the connection shows as "Connected"

3. **If no warnings appear**, connections are already configured (this is common when the same connectors are used in other agents in the environment)

#### Step 2i: Test in Preview

1. Click the **"Preview"** tab
2. Send a test message related to the agent's knowledge domain
3. Verify the agent responds with knowledge-based answer
4. If the agent has escalation flows, test with the trigger phrase
5. Verify the agent starts asking for information conversationally
6. Report test results to user

#### Step 2j: Publish (Optional - Ask User First)

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
2. Workflow の追加:
   - "Add a tool" → "Workflow" → "{flowName}"
   - Flow ID: {flowId}
3. Connector の追加（該当する場合）:
   - "Add a tool" → "{connectorName}"
4. Connected Agents の追加（該当する場合）:
   - "Connected agents" → エージェント検索 → 追加
5. Knowledge Source の追加（SharePoint/URL/Files がある場合）:
   - "Knowledge" → "Add knowledge" → ソース追加
6. Code Interpreter の有効化（Classic で有効だった場合）:
   - Build ページで Code Interpreter トグルを ON
7. AI Builder プロンプトの再構成（該当する場合）:
   - "Add a tool" → プロンプト内容をコピーして設定
   - 元のプロンプト: {promptText}
8. Connection の認証: 各 Tool の Configure → Sign in
9. Preview タブでテスト
10. Publish

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
