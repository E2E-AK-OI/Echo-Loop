[Document Center](/help/en)

All Products

* [Document Center](/help/en "Document Center")
* [Alibaba Cloud Model Studio](/help/en/model-studio/ "Alibaba Cloud Model Studio")
* [API Reference (Models)](/help/en/model-studio/model-api-reference/ "API Reference (Models)")
* [Audio](/help/en/model-studio/audio-api-references/ "Audio")
* [Speech synthesis](/help/en/model-studio/speech-synthesis-api-reference/ "Speech synthesis")
* [Real-time speech synthesis](/help/en/model-studio/realtime-tts-model-apis/ "Real-time speech synthesis")
* [Qwen-Audio-TTS](/help/en/model-studio/qwen-audio-tts-api/ "Qwen-Audio-TTS")
* [Client events](/help/en/model-studio/qwen-audio-tts-client-events "Client events")

 [Document Center](/help/en)

# Alibaba Cloud Model Studio:Qwen-Audio-TTS client events

Last Updated:Oct 29, 2026

## run-task

Starts a speech synthesis task and configures the model, voice, sample rate, and other parameters.

**When to send**: Immediately after the WebSocket connection is established.

**Response event**: The server returns a task-started event. Wait for this event before sending subsequent commands.

|  |  |
| --- | --- |
| **header** `object`**(required)**  **action** `string`**(required)**  The command type. Set to `run-task`.  **task\_id** `string`**(required)**  A client-generated task ID in UUID format. This ID correlates subsequent events and must match the task\_id in th
e continue-task and finish-task commands.  **streaming** `string`**(required)**  Set to `duplex`.  **payload** `object`**(required)**  Properties  **task\_group** `string`**(required)**  The task group. Set to `audio`.  **task** `string`**(required)**  The tas
k type. Set to `tts`.  **function** `string`**(required)**  The function type. Set to `SpeechSynthesizer`.  **model** `string`**(required)**  The model name.  **input** `object`**(required)**  Set to an empty object `{}`. Send the text to synthesize through th
e continue-task command.  **parameters** `object`**(required)**  Speech synthesis parameters.  Properties  **text\_type** `string`**(required)**  Set to `PlainText`.  **voice** `string`**(required)**  The voice used for speech synthesis.   * **System voices**:
 See [Qwen-Audio-TTS voice list](/help/en/model-studio/qwen-audio-tts-voice-list) * **Cloned voices**: Custom voices created through voice cloning * **Custom voices**: Custom voices created through voice design   **format** `string`(optional)  The audio encodi
ng format.  Valid values:   * pcm * wav * mp3 (default) * opus   **sample\_rate** `integer`(optional)  The audio sample rate in Hz.  Valid values: 8000, 16000, 22050 (default), 24000, 44100, 48000.  **volume** `integer`(optional)  The volume level.  Default va
lue: 50.  Valid values: [0, 100].  **rate** `float`(optional)  The speech rate.  Default value: 1.0.  Valid values: [0.5, 2.0].  **pitch** `float`(optional)  The pitch.  Default value: 1.0.  Valid values: [0.5, 2.0].  **bit\_rate** `integer`(optional)  The aud
io bit rate in kbps. When the audio format is mp3 or opus, use `bit_rate` to adjust the bit rate.  Default value: 32.  Valid values: [6, 510].  **enable\_ssml** `boolean`(optional)  Specifies whether to enable SSML.  Default value: false.  When set to true, on
ly one continue-task command is allowed.  For the SSML usage restrictions (supported models, voices, and APIs), see [Limitations](/help/en/model-studio/ssml-latex-user-guide#sl01_constraint_h3).  **word\_timestamp\_enabled** `boolean`(optional)  Specifies whet
her to enable word-level timestamps.  Default value: false.  Available only in streaming output mode. Cloned voices are supported. For supported system voices, see [Qwen-Audio-TTS voice list](/help/en/model-studio/qwen-audio-tts-voice-list).  **seed** `integer
`(optional)  A random seed for controlling variation in the synthesis output. When the model version, text, voice, and other parameters are unchanged, using the same seed produces identical results.  Default value: 0.  Valid values: [0, 65535].  **language\_hi
nts** `array[string]`(optional)  **Important**   * This parameter is an array, but the current version only processes the first element. Pass a single value. * This parameter specifies the target language for speech synthesis. It's unrelated to the language of
 the audio sample used in voice cloning. To set the source language for a cloning task, see the [voice cloning API reference](/help/en/model-studio/voice-clone-design-http-api#h2-create).  Specifies the target language for speech synthesis to improve output qu
ality.  When digit pronunciation, abbreviation expansion, symbol reading, or minority-language synthesis doesn't meet expectations, use this parameter. For example:   * Unexpected digit pronunciation: "hello, this is 110" is read as "hello, this is one zero" i
nstead of the expected Chinese pronunciation * Inaccurate symbol pronunciation: "@" is read as the Chinese equivalent instead of "at" * Poor minor language synthesis quality with unnatural results   Valid values  * zh: Chinese * en: English * fr: French * de:
German * ja: Japanese * ko: Korean * ru: Russian * pt: Portuguese * th: Thai * id: Indonesian * vi: Vietnamese * es: Spanish * it: Italian * ms: Malaysian * fil: Filipino * ar: Arabic * other: Other languages (supported by `qwen-audio-3.1-tts-flash`)  Bulgaria
n, Dutch, Hungarian, Romanian, Danish, Croatian, Greek, Czech, Norwegian, Swedish, Hindi, Slovak, Finnish, Urdu, Serbian, Mexican Spanish, Lithuanian, Latvian, Turkish, Persian, Hebrew, Mongolian, Slovenian, Azerbaijani, Polish, Catalan, Khmer, Brazilian Portu
guese, Lao, Georgian, Afrikaans, Nepali, Belarusian, Malayalam, Luxembourgish, Albanian, Tamil, Sinhala, Telugu, Estonian, Cebuano, Bosnian, Burmese, Armenian, Latin, Icelandic, Maltese, Swahili, Kazakh, Seychellois Creole, Ukrainian.  **instruction** `string`
(optional)  Sets an instruction to control dialect, emotion, or voice character during synthesis. For detailed usage, see [Instruction control](/help/en/model-studio/realtime-tts-user-guide#12884a10929p9).  **enable\_aigc\_tag** `boolean`(optional)  Specifies
whether to embed an AIGC watermark in the generated audio. When set to true, the watermark is embedded in audio files of supported formats (wav/mp3/opus).  Default value: false.  **aigc\_propagator** `string`(optional)  Sets the `ContentPropagator` field in th
e AIGC watermark, identifying the content propagator. Takes effect only when `enable_aigc_tag` is `true`.  Default value: Alibaba Cloud UID.  **aigc\_propagate\_id** `string`(optional)  Sets the `PropagateID` field in the AIGC watermark, uniquely identifying a
 specific propagation action. Takes effect only when `enable_aigc_tag` is `true`.  Default value: The request ID of the current speech synthesis request.  **hot\_fix** `object`(optional)  Configures pronunciation corrections and text replacements applied befor
e synthesis.  Parameters:   * pronunciation: Custom pronunciation. Specifies pinyin annotations for words to correct inaccurate default pronunciations. * replace: Text replacement. Replaces specified words with target text before synthesis. The replaced text i
s used as the actual synthesis input.   Example:   ``` "hot_fix": { "pronunciation": [ {"weather": "tian1 qi4"} ], "replace": [ {"today": "gold day"} ] }  ``` | ``` { "header": { "action": "run-task", "task_id": "2bf83b9a-baeb-4fda-8d9a-xxxxxxxxxxxx", "streami
ng": "duplex" }, "payload": { "task_group": "audio", "task": "tts", "function": "SpeechSynthesizer", "model": "qwen-audio-3.0-tts-flash", "parameters": { "text_type": "PlainText", "voice": "longanlingxi", "format": "mp3", "sample_rate": 22050, "volume": 50, "r
ate": 1.0, "pitch": 1.0, "enable_ssml": false }, "input": {} } }  ``` |

## continue-task

Sends the text to synthesize. The text can be sent all at once or in multiple segments.

**When to send**: After receiving the task-started event from the server.

**Limits**:

* Maximum of 20,000 characters per message
* Maximum of 200,000 characters cumulatively
* The send interval must not exceed 23 seconds; otherwise, the connection times out.

|  |  |
| --- | --- |
| **header** `object`**(required)**  Properties  **action** `string`**(required)**  The command type. Set to `continue-task`.  **task\_id** `string`**(required)**  The task ID in UUID format. Must match the task\_id in run-task.  **streaming** `string`**(requi
red)**  Set to `duplex`.  **payload** `object`**(required)**  Properties  **input** `object`**(required)**  Contains the text to synthesize.  **text** `string`**(required)**  The text to synthesize. Maximum of 20,000 characters per message and 200,000 characte
rs cumulatively. | ``` { "header": { "action": "continue-task", "task_id": "2bf83b9a-baeb-4fda-8d9a-xxxxxxxxxxxx", "streaming": "duplex" }, "payload": { "input": { "text": "Before my bed, moonlight shines bright, I suspect it's frost upon the ground." } } }  `
`` |

## finish-task

Notifies the server that all text has been sent and requests task completion.

**When to send**: Immediately after all text has been sent.

**Response event**: The server returns a task-finished event.

|  |  |
| --- | --- |
| **header** `object`**(required)**  Properties  **action** `string`**(required)**  The command type. Set to `finish-task`.  **task\_id** `string`**(required)**  The task ID in UUID format. Must match the task\_id in run-task.  **streaming** `string`**(require
d)**  Set to `duplex`.  **payload** `object`**(required)**  Properties  **input** `object`**(required)**  Set to `{}` for normal task completion. Include `directive` to cancel the current synthesis turn.  **directive** `string`(optional)  Controls how the task
 ends. Currently only `cancel` is supported. When set to `cancel`, the current synthesis turn is canceled and the server immediately returns a `task-finished` event without producing further audio.  After cancellation, you can start a new synthesis task on the
 same WebSocket connection by sending a new `run-task` event without reconnecting. | ``` { "header": { "action": "finish-task", "task_id": "2bf83b9a-baeb-4fda-8d9a-xxxxxxxxxxxx", "streaming": "duplex" }, "payload": { "input": {} } }  ```   **Cancel task exampl
e**:   ``` { "header": { "action": "finish-task", "task_id": "2bf83b9a-baeb-4fda-8d9a-xxxxxxxxxxxx", "streaming": "duplex" }, "payload": { "input": { "directive": "cancel" } } }  ``` |

Thank you! We've received your feedback.
