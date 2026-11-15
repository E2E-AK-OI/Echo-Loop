[Document Center](/help/en)

All Products

Search

 [Document Center](/help/en)

# :WebSocket connection guide

Last Updated:Nov 06, 2026

This topic describes the service endpoint, request headers, and interaction flow for accessing the Qwen-Audio-ASR-Streaming real-time speech recognition service over a WebSocket connection.

## Service endpoint

The WebSocket URL is fixed:

#### Singapore

`wss://{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/inference`

Replace `{WorkspaceId}` with your actual [Workspace ID](/help/en/model-studio/regions#h2_migrate_domain).

#### China (Beijing)

`wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference`

Replace `{WorkspaceId}` with your actual [Workspace ID](/help/en/model-studio/regions#h2_migrate_domain).

**Important**Alibaba Cloud Model Studio has released workspace-specific domains for the China (Beijing) and Singapore regions. The new dedicated domains deliver superior performance and higher stability for inference requests. We recommend migrating to the new domains:

* China (Beijing): from `dashscope.aliyuncs.com` to `{WorkspaceId}.cn-beijing.maas.aliyuncs.com`
* Singapore: from `dashscope-intl.aliyuncs.com` to `{WorkspaceId}.ap-southeast-1.maas.aliyuncs.com`

## Request headers

Add the following information to the request header:

| **Parameter** | **Type** | **Required** | **Description** |
| --- | --- | --- | --- |
| `Authorization` | `string` | Yes | Authentication token in the format `Bearer` . Replace  with your actual API key. |
| `user-agent` | `string` | No | Client identifier that helps the server track the request source. |
| `X-DashScope-WorkSpace` | `string` | No | Model Studio workspace ID. |
| `X-DashScope-DataInspection` | `string` | No | Whether to enable data compliance inspection. This parameter is omitted or set to `enable` by default. Do not enable this parameter unless necessary. |

**Important**Authorization is verified during the WebSocket handshake. If the API key is invalid or missing, the handshake fails and returns an HTTP 401 or 403 error.

## Interaction flow

For details about client events and server events, see [Client events](/help/en/model-studio/qwen-audio-asr-streaming-client-events) and [Server-side events](/help/en/model-studio/qwen-audio-asr-streaming-server-events).

![WebSocket speech recognition sequence](https://help-static-aliyun-doc.aliyuncs.com/assets/img/en-US/3082892871/CAEQUBiBgMCriYSA2RkiIGY1NDE4OTBjOGM3NTRiNjc4MGQ1YzRiMmE3YWQ3ODE44709861_20241015153444.149.svg)

The client and server interact in the following order:

1. Establish the connection: The client establishes a WebSocket connection to the server.
2. Start the task: The client sends a run-task instruction to start the task and receives a task-started event from the server. This event confirms that the task has started and that you can proceed to the subsequent steps.
3. Send the audio stream: The client starts sending binary audio (which must be mono) and simultaneously receives a stream of result-generated events from the server. Each event contains a speech recognition result.
4. Notify the server to end the task: The client sends a finish-task instruction to signal the server to end the task and continues to receive result-generated events from the server.
5. End the task: The client receives a task-finished event from the server, which indicates that the task has ended.
6. Close the connection: The client closes the WebSocket connection.

Thank you! We've received your feedback.
