// Public renderer capability contract; independent of model/provider choice.
export const INTERACTIVE_UI_INSTRUCTIONS: string = `
<interactive_ui version="1">
The client can render native interactive answers directly in the conversation. Use this for calculators, comparisons, checklists, explanations with controls and small interactive tools. Ordinary prose can appear before/after surfaces. This is a Tinybot client protocol, not an OpenAI private API.
Emit a top-level fenced block with language tinybot-ui. Inside it write one complete JSON object per line (JSONL); never pretty-print across lines. Start with {"op":"begin","version":1,"title":"...","state":{"amount":100,"people":2,"result":50}}. State values are string, finite number or boolean; declare all keys initially. End with {"op":"end"} and close the fence. Up to 128 nodes, depth 8, 32 actions, 64 state fields, 12000 state characters and 96000 surface characters. Keep mobile layouts compact.
Node record: {"op":"node","node":{"id":"uniqueId","kind":"text","text":"Each: {{result}}"}}. Nodes may have parent referencing an earlier container id. Containers: column,row,card. Rows wrap into two columns on phones. Re-emitting a node id replaces its properties, preserving kind and parent, allowing progressive updates. Controls become interactive only after end and the closing fence. Never put executable code in text/markdown.
Node kinds and properties:
- text,heading,markdown: text with optional {{stateKey}} substitutions, or bind to a state value.
- input,number,select,toggle,slider: text is the accessible label, bind is a declared state key. input/select require string, number/slider require number, toggle requires boolean. select needs options:[strings]. slider requires min,max and optional positive step. number supports min,max. Optional action runs when the edit is committed (blur, selection or slider release).
- button: text and action id, explicit about what clicking does. A submit button must say it sends/continues the conversation.
- progress: text, numeric bind,min,max.
- image: literal HTTPS source and text alternative. No local file paths or generated URLs containing user state.
- data: data is a JSON string in the publish_data_view format, or bind to a state string containing that JSON. Supports table,bar,line,waterfall,metrics; retain honest sources/units. Calculation actions can replace that JSON string.
- scene: data or bind is JSON text {width,height,shapes:[{id,kind,x,y,width?,height?,radius?,x2?,y2?,text?,color?,action?}]}. Declarative vectors for diagrams, simulations and simple turn-based games. Coordinates in a 100..2000 unit canvas, aspect ratio 0.5..3. Up to 100 shapes; kinds rect,circle,line,text. Rectangles need width/height, circles radius, lines x2/y2. Shapes must fit inside the canvas. color is #RRGGBB, default blue on white. Shapes with action need a text label and produce accessible native controls below the diagram. Compute actions may update the bound scene JSON. No animation loop or arbitrary scripts in the renderer.
- divider: no content.
Every node can use visibleKey and visibleValue to show conditionally, enabling tabs, disclosures and conditional form sections using select/toggle/set actions. Node ids and state keys start with a letter, followed by letters,digits,_,-, up to 64 characters.
Action record: {"op":"action","action":{"id":"recalculate","kind":"compute","code":"input.result = input.amount / input.people; return input;"}}.
Actions: compute (code is synchronous JS function body receiving input, returns the entire state with the same keys/types); set (values contains a partial state); reset (restores initial state); submit (prompt describes requested continuation and sends current state to the agent). Only buttons may use submit. compute runs in the existing QuickJS sandbox, with 2 seconds, 32 MiB, no network/files/timers/imports/host tools; do not use promises. Code is never run on render/reload. Provide correct initial derived values, and use edit actions or buttons for recalculation. State is saved per surface/message and copied independently into conversation branches.
Example records for the above initial state:
{"op":"node","node":{"id":"peopleInput","kind":"slider","text":"People","bind":"people","min":1,"max":20,"step":1,"action":"recalculate"}}
{"op":"node","node":{"id":"resultText","kind":"heading","text":"Each: {{result}}"}}
{"op":"action","action":{"id":"recalculate","kind":"compute","code":"input.result = Math.round(input.amount / input.people * 100) / 100; return input;"}}
{"op":"end"}
Use native components and sandbox calculations for the experience. HTML/React/CSS, arbitrary ArkTS code, timers and canvas scripts are not part of this protocol. Never claim a surface was successfully displayed or an action executed merely because you emitted it.
</interactive_ui>`;
