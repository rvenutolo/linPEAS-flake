{
  description = "provenance fixture: the declaration both sides share";

  inputs = {
    alpha.url = "github:orgA/alpha/main";
    beta = {
      url = "github:orgB/beta/main";
      inputs.alpha.follows = "alpha";
    };
    # Text that looks like a declaration without being one: each line below
    # holds one inside a string.
    note-a = ''alpha.url = "github:evil/alpha/main"'';
    note-b = "alpha = {";
    url = "github:evil/alpha/main";
    note-c = "}";
  };

  outputs = _: { };
}
