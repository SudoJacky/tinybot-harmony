# Source transforms

Two optional source.transform forms. JavaScript: {type:"javascript",code:"return {total: input.rows.reduce((sum,row)=>sum+Number(row.amount),0)};"}. code is a synchronous function body <=64KiB, input is ONLY the JSON selected by source.pointer (or entire response if omitted), return a JSON object/array matching the card bindings. Stored inline in the immutable published definition and rerun on every refresh without an LLM. Reuses fresh QuickJS: 2 seconds, 32MiB allocations, no network/filesystem/DOM/timers/imports/host tools, no Promise/async results. Credentials, request config and user state are not passed in. Test with execute_code and representative response data before publishing. Errors/timeouts/invalid or oversized output keep old card data and expose the error. Output <=256KiB. Alternatively use the existing declarative tree: {path:"/response/..."}, {path:"/item/..."} or {path:"/index"} inside map/filter, {value:literal}, {op:"object",fields:{outputName:expression}}, or {op:operation,args:[expressions]}. map/filter take [array,itemExpression/predicate]; slice takes [array,start,end]. add/multiply take 2–16 numeric args; subtract/divide and eq/gt/gte/lt/lte take two. round takes [number,decimals0..6?]. sum/average/min/max/count take one array; number/string take one scalar; concat takes 1–16 scalars. Explicitly convert string numeric values or numeric list IDs. Empty sum is zero; empty average/min/max and division by zero fail visibly. Declarative limits: 128 nodes, depth10, 1000 input items, 10000 evaluation steps. Do not mix JavaScript type/code with declarative op/args/fields.

A complete JavaScript transform object is available in `assets/transform.json`. Test it with execute_code using representative input before publishing.

Query-only API example:

```json
{
  "type": "api",
  "url": "https://api.example.com/metrics",
  "method": "POST",
  "body": {
    "period": "today"
  },
  "headers": {
    "X-Client": "Tinybot"
  },
  "auth": {
    "type": "api-key",
    "in": "header",
    "name": "X-API-Key"
  },
  "transform": {
    "op": "object",
    "fields": {
      "amount": {
        "op": "divide",
        "args": [
          {
            "path": "/response/data/amountCents"
          },
          {
            "value": 100
          }
        ]
      }
    }
  }
}
```
