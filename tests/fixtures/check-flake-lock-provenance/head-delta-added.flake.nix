{
  description = "provenance fixture: the declaration both sides share";

  inputs = {
    alpha.url = "github:orgA/alpha/main";
    delta.url = "github:orgD/delta/main";
    beta = {
      url = "github:orgB/beta/main";
      inputs.alpha.follows = "alpha";
    };
  };

  outputs = _: { };
}
