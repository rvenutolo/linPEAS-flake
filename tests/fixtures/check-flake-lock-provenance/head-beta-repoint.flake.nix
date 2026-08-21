{
  description = "provenance fixture: the declaration both sides share";

  inputs = {
    alpha.url = "github:orgA/alpha/main";
    beta = {
      url = "github:orgB/beta/next";
      inputs.alpha.follows = "alpha";
    };
  };

  outputs = _: { };
}
