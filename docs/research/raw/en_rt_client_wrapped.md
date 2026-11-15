[Document Center](/help/en)

All Products

* [Document Center](/help/en "Document Center")
* [Alibaba Cloud Model Studio](/help/en/model-studio/ "Alibaba Cloud Model Studio")
* [API Reference (Models)](/help/en/model-studio/model-api-reference/ "API Reference (Models)")
* [Audio](/help/en/model-studio/audio-api-references/ "Audio")
* [Voice Conversation API Reference](/help/en/model-studio/voice-conversation-api-references/ "Voice Conversation API Reference")
* [Real-time voice conversation](/help/en/model-studio/realtime-dialogue-model-apis/ "Real-time voice conversation")
* [Qwen-Audio-Realtime](/help/en/model-studio/real-time-voice-conversation-api-references/ "Qwen-Audio-Realtime")
* [Client events](/help/en/model-studio/fun-audiochat-client-events "Client events")

 [Document Center](/help/en)

# Alibaba Cloud Model Studio:Qwen-Audio client events

Last Updated:Oct 28, 2026

Client event reference for the Qwen-Audio Realtime API.

**User guide**: [Realtime Audio Chat (Qwen-Audio-Realtime)](https://www.alibabacloud.com/help/model-studio/qwen-audio-realtime-user-guides). For event interaction sequences, see [WebSocket API](/help/en/model-studio/fun-audiochat-realtime-websocket-api).

## session.update

**Description**: After a connection is established, send this event to update the default session configuration. Include only the fields you want to change; omitted fields retain their current values. If any parameter is invalid, the server returns an error. If all parameters are
 valid, the server applies the changes and returns the full configuration.

**Note**`turn_detection` can only be modified before the first audio is sent (IDLE state).

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `session.update`.  **session**`object` (optional)  Session configuration.  **modalities**`array` (optional)  Output modalities for the model. Valid values:   * `["text"]`  Text only. * `["audio", "text"]` (default)  Both
text and audio.   **voice**`string` (optional)  TTS voice name. The default is `longanqian_v3.1` for 3.1 Plus/Flash and `longanqian` for 3.0 Plus/Flash. System voices and cloned voices are supported. Can only be set in the first `session.update`; ignored in subsequent calls.   *
**System voices for 3.1 Plus/Flash**: Supports `longanqian_v3.1` and the union of the voice lists for 3.1 TTS Plus and Flash. For the complete range, see [Voice configuration](/help/en/model-studio/qwen-audio-realtime-user-guides#fc60h311). * **System voices for 3.0 Plus/Flash**:
 Available values: `longanqian`, `longanlingxin`, `longanlingxi`, `longanxiaoxin`, `longanlufeng`. * **Cloned voices**: created via the Voice Cloning API. Pass the returned `voice_id` as this parameter's value. For details, see [Voice configuration](https://www.alibabacloud.com/h
elp/model-studio/qwen-audio-realtime-user-guides#fc60h311).   After connecting to `qwen-audio-3.1-realtime-plus` or `qwen-audio-3.1-realtime-flash`, set the voice in the first `session.update`, for example:   ``` { "type": "session.update", "session": { "voice": "longanqian_v3.1"
 } }  ```   **speech\_rate**`float` (optional)  Controls the speaking rate of model audio output. Range: `[0.5, 2.0]`. Default: `1.0`. Lower values slow the speech; higher values speed it up. Supported by `qwen-audio-3.1-realtime-plus`, `qwen-audio-3.1-realtime-flash`, `qwen-audi
o-3.0-realtime-plus`, `qwen-audio-3.0-realtime-flash`.  **enable\_speech\_emotion**`boolean` (optional)  Specifies whether to enable speech emotion enhancement. When enabled, the response voice exhibits more pronounced emotional variations. Default: `true`. Valid values: `true` a
nd `false`.  **instructions**`string` (optional)  System instructions that define the model's role, response style, and behavioral preferences. Applies to the entire session.  **input\_audio\_format**`string` (optional)  Input audio format. Currently only `pcm` (16 kHz, 16-bit, m
ono) is supported and is the default. Can only be modified before the first audio is sent (IDLE state).  **output\_audio\_format**`string` (optional)  Output audio format. Currently only `pcm` (24 kHz, 16-bit, mono) is supported and is the default.  **input\_audio\_transcription*
*`object` (optional)  Input audio transcription configuration. Applies to `qwen-audio-3.1-realtime-plus` and `qwen-audio-3.1-realtime-flash`.  Properties  **language**`string` (optional)  The source language of the input audio.  Valid values:   * `zh`: Chinese * `en`: English * `
ja`: Japanese * `ko`: Korean * `vi`: Vietnamese * `th`: Thai * `id`: Indonesian * `ar`: Arabic * `fr`: French * `de`: German * `es`: Spanish * `pt`: Portuguese * `ru`: Russian * `it`: Italian  **output\_audio**`object` (optional)  Output audio configuration. Applies to `qwen-audi
o-3.1-realtime-plus` and `qwen-audio-3.1-realtime-flash`.  Properties  **language**`string` (optional)  The target language of the output audio.  This parameter applies to speech synthesis (TTS). The model makes a best effort to produce speech in the target language, but this is
not guaranteed, and the language of the response text is not changed. To generate text in the target language, state the requirement explicitly in the prompt, for example by specifying the reply language in `instructions`.  Valid values:   * `zh`: Chinese * `en`: English * `fr`:
French * `de`: German * `ja`: Japanese * `ko`: Korean * `ru`: Russian * `pt`: Portuguese * `th`: Thai * `id`: Indonesian * `vi`: Vietnamese * `es`: Spanish * `it`: Italian * `ar`: Arabic  **max\_history\_turns**`integer` (optional)  Maximum number of conversation turns (question-
answer pairs) included in a single request. Valid values: 1 to 50. Default: 20.  **enable\_search**`boolean` (optional) **Applies to the qwen-audio-3.1-realtime-plus, qwen-audio-3.1-realtime-flash, qwen-audio-3.0-realtime-plus, and qwen-audio-3.0-realtime-flash models.** Specifie
s whether to enable web search. Default: `false`. When enabled, the model decides whether to search the web based on the real-time query.  `qwen-audio-3.1-realtime-flash` supports enabling `tools` and `enable_search` together. `qwen-audio-3.1-realtime-plus`, `qwen-audio-3.0-realt
ime-plus`, and `qwen-audio-3.0-realtime-flash` do not support enabling them together.  **search\_options**`object` (optional)  The web search configuration. This parameter takes effect only when `enable_search` is set to `true`.  Properties  **enable\_source**`boolean` (optional)
  Specifies whether to return the sources of search results. Set this parameter to `true` to return the sources.  **tools**`array` (optional)  Tool definitions for Function Calling. Once configured, the model decides whether to call a tool based on user input.  Properties  **type
**`string`**(required)**  Fixed value: `function`.  **function.name**`string`**(required)**  Name of the tool function.  **function.description**`string` (optional)  Description of the tool function. The model uses this to determine whether to call the tool.  **function.parameter
s**`object` (optional)  Description of the tool function's input parameters. The model uses this to extract the required parameters. Omit this field if the function takes no parameters.  Properties  **type**`string`**(required)**  Fixed value: `object`.  **properties**`object` (o
ptional)  Describes each parameter's name, data type, and description.  **required**`array` (optional)  Specifies which parameters are required.  **turn\_detection**`object|null` (optional)  The turn detection fields described below apply to `qwen-audio-3.1-realtime-plus`, `qwen-
audio-3.1-realtime-flash`, `qwen-audio-3.0-realtime-plus`, and `qwen-audio-3.0-realtime-flash`.  Turn detection configuration. To switch to push-to-talk mode, set this field to `null`. In push-to-talk mode, audio must be committed manually and inference triggered manually. If thi
s field isn't provided, VAD is enabled with its default parameters.  Properties  **type**`string` (optional)  VAD type. Valid values:   * `server_vad` (default): Detects speech onset and offset based on acoustic features and automatically triggers inference. * `smart_turn`: An in
telligent turn detection mode that combines acoustic perception and semantic understanding to determine turn boundaries. Filler sounds such as "um" or "uh" don't trigger a new turn or interrupt model playback. * `smart_turn_v2` (recommended): Builds on `smart_turn` to better unde
rstand conversation context and interaction intent in multi-speaker settings. Reduces unintended responses or interruptions caused by bystanders or unrelated interjections.   **threshold**`float` (optional)  VAD sensitivity. Applies to `server_vad`, `smart_turn`, and `smart_turn_
v2`. Lower values increase VAD sensitivity, making it easier to detect faint sounds (including background noise) as speech. Higher values decrease sensitivity, requiring clearer and louder speech to trigger detection.  Range: [-1.0, 1.0]. Default: 0.5.  **silence\_duration\_ms**`
integer` (optional)  Minimum silence duration (in milliseconds) after speech ends before triggering a model response. Only effective in server\_vad mode (ignored in smart\_turn / smart\_turn\_v2 modes). Lower values produce faster responses but may cause false triggers during bri
ef pauses.  Range: [200, 6000]. Default: 800. Recommended range for conversations: 400-800.  **voiceprint\_audio\_urls**`array` (optional)  **Only effective in smart\_turn / smart\_turn\_v2 modes.** A list of publicly accessible URLs pointing to pre-recorded audio samples from th
e target user, used for speaker enhancement. Once registered, the model locks onto the target speaker during duplex conversations, effectively ignoring other voices and background noise. Maximum 5 URLs. Audio format requirements: 16kHz PCM or WAV.  **Important**This parameter can
 only be configured in the **first** `session.update` event. It is ignored in subsequent `session.update` events. | The examples below apply to `qwen-audio-3.1-realtime-plus` and `qwen-audio-3.1-realtime-flash` and explicitly select the system voice `longanqian_v3.1`.   ``` { "ty
pe": "session.update", "session": { "modalities": [ "text", "audio" ], "voice": "longanqian_v3.1", "speech_rate": 1.2, "turn_detection": { "type": "server_vad", "threshold": 0.5, "silence_duration_ms": 800 } } }  ```  **Language configuration (qwen-audio-3.1-realtime-plus / qwen-
audio-3.1-realtime-flash)** After connecting to `qwen-audio-3.1-realtime-plus` or `qwen-audio-3.1-realtime-flash`, you can send the following `session.update` event to set the source language of the input audio to Chinese and the target language of the output audio to English.
``` { "type": "session.update", "session": { "input_audio_transcription": { "language": "zh" }, "output_audio": { "language": "en" } } }  ```   Function Calling:   ``` { "type": "session.update", "session": { "modalities": [ "text", "audio" ], "voice": "longanqian_v3.1", "tools":
 [ { "type": "function", "function": { "name": "get_weather", "description": "Get weather for a specified city", "parameters": { "type": "object", "properties": { "city": { "type": "string", "title": "City" } }, "required": ["city"] } } } ], "turn_detection": { "type": "server_va
d", "threshold": 0.5, "silence_duration_ms": 800 } } }  ```   Voiceprint registration (voiceprint\_audio\_urls):   ``` { "type": "session.update", "session": { "turn_detection": { "type": "smart_turn_v2", "voiceprint_audio_urls": [ "https://example.com/speaker1.pcm", "https://exa
mple.com/speaker2.wav" ] } } }  ``` |

## input\_audio\_buffer.append

**Description**: Appends audio data to the input buffer. Send this event continuously at a high frequency — for example, one chunk every 20–40 ms. The server sends no acknowledgment for this event.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `input_audio_buffer.append`.  **audio**`string`**(required)**  Base64-encoded audio data. | ``` { "type": "input_audio_buffer.append", "audio": "" }  ``` |

## input\_audio\_buffer.commit

**Description**: **Push-to-talk mode only.** Commits the buffered audio as a user message. This doesn't automatically trigger inference. Send `response.create` to trigger inference manually.

This event is ignored in server\_vad, smart\_turn, and smart\_turn\_v2 modes.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `input_audio_buffer.commit`. | ``` { "type": "input_audio_buffer.commit" }  ``` |

## input\_audio\_buffer.clear

**Description**: **Push-to-talk mode only.** Clears uncommitted audio from the buffer. This event is ignored in server\_vad, smart\_turn, and smart\_turn\_v2 modes. The server responds with an `input_audio_buffer.cleared` event.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `input_audio_buffer.clear`. | ``` { "type": "input_audio_buffer.clear" }  ``` |

## conversation.item.create

**Description**: Inserts a conversation item into the conversation context. Use this event to inject historical context or add text content, or to return Function Calling results.

**Note**If `item.id` already exists in the conversation, an error is returned and the item isn't created.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `conversation.item.create`.  **previous\_item\_id**`string` (optional)  Specifies the conversation item after which the new item is inserted. If not provided, the item is appended to the end of the conversation.  **item**
`object`**(required)**  The conversation item to create.  Properties  **id**`string` (optional)  Unique identifier for the conversation item. If not provided, the server generates one automatically. An error is returned if the specified ID already exists in the conversation.  **t
ype**`string`**(required)**  Conversation item type. Valid values:   * `message`: A regular conversation message. * `function_call`: A function call request. Typically generated by the server, but clients can also use it to inject historical context. * `function_call_output`: A t
ool execution result. After receiving a `function_call`, the client executes the tool and returns the result using this type.   **role**`string` (required for `message` type)  Message role. Valid values: `system`, `user`, `assistant`.  **content**`array` (required for `message` t
ype)  List of message content elements. Each element contains a `type` field and corresponding data fields.  Supported content types by role  **system** `input_text`: System message. Required field: `text`. **user**  * `input_text`: User text input. Required field: `text`. * `inp
ut_audio`: User audio input. Required field: `audio` (Base64-encoded).  **assistant** `output_text`: Assistant text output. Required field: `text`.  **call\_id**`string` (required for `function_call` / `function_call_output` type)  Unique identifier for the function call, used to
 correlate requests and results.  **name**`string` (required for `function_call` type)  Name of the function to call.  **arguments**`string` (required for `function_call` type)  Function call parameters in JSON string format.  **output**`string` (required for `function_call_outpu
t` type)  Tool execution result in JSON string format. | Inject a user text message:   ``` { "type": "conversation.item.create", "previous_item_id": "item_xxx", "item": { "id": "my_item_001", "type": "message", "role": "user", "content": [ { "type": "input_text", "text": "Please
summarize our last conversation" } ] } }  ```   Return a Function Calling result:   ``` { "type": "conversation.item.create", "item": { "type": "function_call_output", "call_id": "call_xxx", "output": "{\"temperature\":18,\"condition\":\"sunny\"}" } }  ``` |

## conversation.item.retrieve

**Description**: Retrieves a conversation item stored on the server. Audio-type content in the response contains only the transcript (`transcript`), not the original audio data.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `conversation.item.retrieve`.  **item\_id**`string`**(required)**  ID of the conversation item to retrieve. The server returns the result in a `conversation.item.retrieved` event. | ``` { "type": "conversation.item.retrie
ve", "item_id": "item_xxx" }  ``` |

## conversation.item.delete

**Description**: Deletes a conversation item from the conversation context. The server confirms the deletion with a `conversation.item.deleted` event.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `conversation.item.delete`.  **item\_id**`string`**(required)**  ID of the conversation item to delete. | ``` { "type": "conversation.item.delete", "item_id": "item_xxx" }  ``` |

## response.create

**Description**: Triggers model inference. Behavior varies by mode:

* **Push-to-talk mode**: Must be called manually. Commit the buffered audio with `input_audio_buffer.commit` first, or return a `function_call_output` result before triggering. Can't be called while a response is being generated.
* **server\_vad mode**: Typically triggered automatically by the server. Clients can also call it manually when no response is being generated. Can't be called while a response is being generated.
* **smart\_turn / smart\_turn\_v2 modes**: Can be called while waiting for the next user turn. Can't be called during an active turn (between `input_audio_buffer.speech_started` and `response.done`).

The optional `response` field overrides the session defaults for the current inference round. In Function Calling scenarios, after the client returns a `function_call_output`, this event triggers the second inference round.

**Note**In server\_vad, smart\_turn, and smart\_turn\_v2 modes, manually triggered inferences can still be interrupted by new speech.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `response.create`.  **response**`object` (optional)  Overrides the session defaults for the current inference round. If not provided, the current session configuration is used.  Properties  **modalities**`array` (optional
)  Overrides the output modalities for the current round. Valid values are the same as `session.update` `modalities`.  **voice**`string` (optional)  Overrides the TTS voice for the current round. | ``` { "type": "response.create", "response": { "modalities": ["audio", "text"] } }
  ``` |

## response.cancel

**Description**: Cancels the current inference. Any text generated so far is saved to the item list. The server then returns a `response.done` event with `status=cancelled`.

An error is returned if no inference is in progress.

|  |  |
| --- | --- |
| **type**`string`**(required)**  Event type. Fixed value: `response.cancel`. | ``` { "type": "response.cancel" }  ``` |

Thank you! We've received your feedback.
