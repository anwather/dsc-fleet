// Deploys the DSC v3 reporting backend:
//   - Log Analytics workspace + 2 custom tables (DscV3Run_CL, DscV3RunSummary_CL)
//   - Data Collection Endpoint (DCE) + Data Collection Rule (DCR)
//   - Storage account, App Service plan (Y1 consumption), Function App (PowerShell 7.4)
//   - Application Insights (workspace-based)
//   - Role assignment: Function MI -> Monitoring Metrics Publisher on the DCR
//
// Usage:
//   az deployment group create -g rg-dscv3 -f main.bicep -p namePrefix=dscv3prod location=australiaeast

@description('Short prefix used to derive resource names (3-12 lowercase alphanum).')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Retention in days for Log Analytics.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

var workspaceName = '${namePrefix}-law'
var dceName       = '${namePrefix}-dce'
var dcrName       = '${namePrefix}-dcr'
var storageName   = take(toLower(replace('${namePrefix}stor${uniqueString(resourceGroup().id)}', '-', '')), 24)
var planName      = '${namePrefix}-plan'
var funcName      = '${namePrefix}-func-${uniqueString(resourceGroup().id)}'
var appiName      = '${namePrefix}-appi'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource summaryTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'DscV3RunSummary_CL'
  properties: {
    schema: {
      name: 'DscV3RunSummary_CL'
      columns: [
        { name: 'TimeGenerated',  type: 'datetime' }
        { name: 'RunId',          type: 'string'   }
        { name: 'Host',           type: 'string'   }
        { name: 'Os',             type: 'string'   }
        { name: 'Group',          type: 'string'   }
        { name: 'Config',         type: 'string'   }
        { name: 'Mode',           type: 'string'   }
        { name: 'Verb',           type: 'string'   }
        { name: 'StartUtc',       type: 'datetime' }
        { name: 'EndUtc',         type: 'datetime' }
        { name: 'ExitCode',       type: 'int'      }
        { name: 'Success',        type: 'boolean'  }
        { name: 'ResourceCount',  type: 'int'      }
        { name: 'DriftedCount',   type: 'int'      }
        { name: 'ArcTagsJson',    type: 'string'   }
      ]
    }
  }
}

resource runTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'DscV3Run_CL'
  properties: {
    schema: {
      name: 'DscV3Run_CL'
      columns: [
        { name: 'TimeGenerated',  type: 'datetime' }
        { name: 'RunId',          type: 'string'   }
        { name: 'Host',           type: 'string'   }
        { name: 'Group',          type: 'string'   }
        { name: 'Config',         type: 'string'   }
        { name: 'ResourceName',   type: 'string'   }
        { name: 'ResourceType',   type: 'string'   }
        { name: 'InDesiredState', type: 'boolean'  }
        { name: 'Drifted',        type: 'boolean'  }
        { name: 'Error',          type: 'string'   }
        { name: 'ResultJson',     type: 'string'   }
      ]
    }
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      'Custom-DscV3RunSummary_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'RunId',         type: 'string'   }
          { name: 'Host',          type: 'string'   }
          { name: 'Os',            type: 'string'   }
          { name: 'Group',         type: 'string'   }
          { name: 'Config',        type: 'string'   }
          { name: 'Mode',          type: 'string'   }
          { name: 'Verb',          type: 'string'   }
          { name: 'StartUtc',      type: 'datetime' }
          { name: 'EndUtc',        type: 'datetime' }
          { name: 'ExitCode',      type: 'int'      }
          { name: 'Success',       type: 'boolean'  }
          { name: 'ResourceCount', type: 'int'      }
          { name: 'DriftedCount',  type: 'int'      }
          { name: 'ArcTagsJson',   type: 'string'   }
        ]
      }
      'Custom-DscV3Run_CL': {
        columns: [
          { name: 'TimeGenerated',  type: 'datetime' }
          { name: 'RunId',          type: 'string'   }
          { name: 'Host',           type: 'string'   }
          { name: 'Group',          type: 'string'   }
          { name: 'Config',         type: 'string'   }
          { name: 'ResourceName',   type: 'string'   }
          { name: 'ResourceType',   type: 'string'   }
          { name: 'InDesiredState', type: 'boolean'  }
          { name: 'Drifted',        type: 'boolean'  }
          { name: 'Error',          type: 'string'   }
          { name: 'ResultJson',     type: 'string'   }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'la'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams:      [ 'Custom-DscV3RunSummary_CL' ]
        destinations: [ 'la' ]
        outputStream: 'Custom-DscV3RunSummary_CL'
      }
      {
        streams:      [ 'Custom-DscV3Run_CL' ]
        destinations: [ 'la' ]
        outputStream: 'Custom-DscV3Run_CL'
      }
    ]
  }
  dependsOn: [ summaryTable, runTable ]
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: appiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: false }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: funcName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',    value: 'powershell' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appi.properties.ConnectionString }
        { name: 'DCE_ENDPOINT',       value: dce.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID',   value: dcr.properties.immutableId }
        { name: 'DCR_STREAM_RUN',     value: 'Custom-DscV3Run_CL' }
        { name: 'DCR_STREAM_SUMMARY', value: 'Custom-DscV3RunSummary_CL' }
      ]
    }
  }
}

// Monitoring Metrics Publisher on the DCR for the Function MI.
var monitoringPublisherRole = '3913510d-42f4-4e42-8a64-420c390055eb'
resource raDcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: dcr
  name: guid(dcr.id, func.id, monitoringPublisherRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringPublisherRole)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output workspaceId        string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output dceEndpoint        string = dce.properties.logsIngestion.endpoint
output dcrImmutableId     string = dcr.properties.immutableId
output functionAppName    string = func.name
output functionUrl        string = 'https://${func.properties.defaultHostName}/api/runs'
