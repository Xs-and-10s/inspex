[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  line_length: 98,
  locals_without_parens: [
    # Inspex spec builders — allow parens-free call style in schemas
    string: 0,
    string: 1,
    string: 2,
    integer: 0,
    integer: 1,
    integer: 2,
    float: 0,
    float: 1,
    float: 2,
    number: 0,
    boolean: 0,
    atom: 0,
    atom: 1,
    map: 0,
    list: 0,
    list: 1,
    list: 2,
    any: 0,
    nil_spec: 0,
    # Combinators
    all_of: 1,
    any_of: 1,
    not_spec: 1,
    maybe: 1,
    list_of: 1,
    ref: 1,
    coerce: 2,
    spec: 1,
    spec: 2,
    cond_spec: 2,
    cond_spec: 3,
    # Schema
    schema: 1,
    open_schema: 1,
    required: 1,
    optional: 1,
    # Registration
    defspec: 2,
    defspec: 3,
    defschema: 1,
    defschema: 2,
    defschema: 3,
    # Signature
    signature: 1
  ]
]
