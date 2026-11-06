// Pure helpers for the Integrations card (kept free of React so node can test them).

export function ago(iso: string | null): string {
  if (!iso) return 'never'
  const secs = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000))
  if (secs < 60) return 'just now'
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`
  return `${Math.floor(secs / 86400)}d ago`
}

/** Home Assistant config snippets, built from the server address and (once) the new token. */
export function haSnippets(origin: string, token: string): { id: string; title: string; text: string }[] {
  return [
    {
      id: 'hacs',
      title: 'Install the integration',
      text: `Copy integrations/home_assistant/custom_components/openfamily from the OpenFamily
repository into your Home Assistant config/custom_components/ (or add the folder to a
HACS custom repository of your own), restart Home Assistant, then
Settings > Devices & services > Add integration > OpenFamily:
  Server URL: ${origin}
  Token:      ${token}`,
    },
    {
      id: 'rest',
      title: 'No custom component? A plain REST sensor',
      text: `# configuration.yaml
rest:
  - resource: ${origin}/integrations/ha/v1/members
    scan_interval: 60
    headers:
      Authorization: "Bearer ${token}"
    sensor:
      - name: "OpenFamily members"
        value_template: "{{ value_json.members | length }}"
        json_attributes:
          - members`,
    },
    {
      id: 'automation',
      title: 'Automation: porch light when someone arrives',
      text: `automation:
  - alias: "Porch light on arrival"
    trigger:
      - platform: event
        event_type: openfamily_arrival
        event_data:
          place: Home
    action:
      - service: light.turn_on
        target: { entity_id: light.porch }`,
    },
  ]
}

