{
  description = "tiny dockerTools image for measure-image-size.sh meta-test";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.tiny-image = pkgs.dockerTools.buildLayeredImage {
        name = "measure-image-size-fixture";
        tag = "test";
        contents = pkgs.buildEnv {
          name = "fixture-root";
          paths = [ pkgs.hello ];
          pathsToLink = [ "/bin" ];
        };
        config.Entrypoint = [ "${pkgs.hello}/bin/hello" ];
      };
    };
}
