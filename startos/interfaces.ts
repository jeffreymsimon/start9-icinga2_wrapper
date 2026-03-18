import { sdk } from './sdk'
import { webPort, apiPort } from './utils'

export const setInterfaces = sdk.setupInterfaces(async ({ effects }) => {
  const httpMulti = sdk.MultiHost.of(effects, 'http-multi')
  const httpOrigin = await httpMulti.bindPort(webPort, {
    protocol: 'http',
  })

  const webUi = sdk.createInterface(effects, {
    name: 'Web UI',
    id: 'web-ui',
    description:
      'IcingaWeb2 dashboard for monitoring hosts, services, and alerts',
    type: 'ui',
    masked: false,
    schemeOverride: null,
    username: null,
    path: '',
    query: {},
  })

  const webUiReceipt = await httpOrigin.export([webUi])

  // Icinga2 API (port 5665) for external sync from Observium
  const apiMulti = sdk.MultiHost.of(effects, 'api-multi')
  const apiOrigin = await apiMulti.bindPort(apiPort, {
    protocol: 'https',
  })

  const apiInterface = sdk.createInterface(effects, {
    name: 'Icinga2 API',
    id: 'icinga2-api',
    description:
      'Icinga2 REST API for external host/service sync and command transport',
    type: 'api',
    masked: false,
    schemeOverride: null,
    username: null,
    path: '',
    query: {},
  })

  const apiReceipt = await apiOrigin.export([apiInterface])

  return [webUiReceipt, apiReceipt]
})
