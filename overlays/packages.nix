{ gpuSupport ? true }:
final: prev:
let
  # Voyager - Spotify's ANN library (not in nixpkgs)
  voyager = final.python312Packages.buildPythonPackage rec {
    pname = "voyager";
    version = "2.1.0";
    format = "wheel";

    src = final.fetchPypi {
      inherit pname version format;
      dist = "cp312";
      python = "cp312";
      abi = "cp312";
      platform = "manylinux_2_17_x86_64.manylinux2014_x86_64";
      hash = "sha256-lBW5ySO6xJPVxo1VrlXEKJFTwj+fR4Qik03mGsuvTAE=";
    };

    # Prebuilt manylinux wheel: patchelf it against the Nix C++ runtime.
    # Without this the extension module cannot resolve libstdc++.so.6, so
    # `import voyager` fails both in the import check and at runtime.
    nativeBuildInputs = [ final.autoPatchelfHook ];
    buildInputs = [ final.stdenv.cc.cc.lib ];

    # Binary wheel, nothing to compile
    propagatedBuildInputs = with final.python312Packages; [ numpy ];

    pythonImportsCheck = [ "voyager" ];

    meta = with final.lib; {
      description = "Spotify's library for approximate nearest-neighbor search";
      homepage = "https://github.com/spotify/voyager";
      license = licenses.asl20;
    };
  };

  # AudioMuse-AI Python environment with all dependencies
  audiomuse-ai-python = final.python312.withPackages (ps: with ps; [
    # Web framework
    flask
    flask-cors
    flasgger
    gunicorn

    # Task queue
    redis
    rq

    # Database
    psycopg2
    sqlglot

    # Audio processing
    librosa
    soundfile
    resampy
    pydub
    mutagen
    av

    # ML/Scientific
    numpy
    scipy
    numba
    scikit-learn
    umap-learn
    transformers
    sentencepiece
    tqdm

    # ONNX
    onnx
    onnxruntime  # CUDA enabled via global cudaSupport = true

    # Utilities
    pyyaml
    requests
    rapidfuzz
    ftfy
    packaging
    protobuf
    httpx
    psutil
    zstandard

    # Auth & Security
    argon2-cffi
    pyjwt

    # Integrations & Language
    langdetect
    python-mpd2
    wn

    # LLM integrations
    google-genai
    mistralai

    # MCP (Model Context Protocol)
    mcp

    # Voyager (from our custom package)
    voyager
  ] ++ final.lib.optionals gpuSupport [
    # GPU-accelerated ML (RAPIDS cuML)
    cupy
    final.python312Packages.rmm
    final.python312Packages.pylibraft
    final.python312Packages.cuvs
    final.python312Packages.cuml
  ]);
in
{
  # AudioMuse-AI - Music analysis and playlist generation service
  audiomuse-ai = final.stdenvNoCC.mkDerivation rec {
    pname = "audiomuse-ai";
    version = "3.6.3";

    src = final.fetchFromGitHub {
      owner = "NeptuneHub";
      repo = "AudioMuse-AI";
      rev = "v${version}";
      hash = "sha256-UX1hSChAAwtRJnbouDHjlNcGP3vyUiaC9q1wEKuB6HA=";
    };

    nativeBuildInputs = [ final.makeWrapper ];

    buildInputs = [
      audiomuse-ai-python
      final.ffmpeg
    ];

    postPatch = ''
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib/audiomuse-ai
      cp -r . $out/lib/audiomuse-ai/

      mkdir -p $out/bin

      # Main Flask app
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai \
        --add-flags "$out/lib/audiomuse-ai/app.py" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      # RQ Worker
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai-worker \
        --add-flags "$out/lib/audiomuse-ai/taskqueue/worker.py" \
        --add-flags "--queue default" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      # High-priority RQ Worker
      makeWrapper ${audiomuse-ai-python}/bin/python $out/bin/audiomuse-ai-worker-high \
        --add-flags "$out/lib/audiomuse-ai/taskqueue/worker.py" \
        --add-flags "--queue high" \
        --prefix PATH : ${final.lib.makeBinPath [ final.ffmpeg ]} \
        --set PYTHONPATH "$out/lib/audiomuse-ai"

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "AI-powered music analysis and playlist generation";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  };

  # AudioMuse-AI ONNX models (v4.0.0-model release)
  # Note: danceability/mood_* models were dropped upstream in v4.0.0; the
  # musicnn embedding/prediction models were renamed.
  audiomuse-ai-models = final.stdenvNoCC.mkDerivation {
    pname = "audiomuse-ai-models";
    version = "4.0.0";

    dontUnpack = true;

    # MusicNN (renamed in v4.0.0-model)
    musicnn_embedding = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/musicnn_embedding.onnx";
      hash = "sha256-pIrYh5UKVXrvu03N31itSAIhP/X8b7Ue2jUHzXl7ubA=";
    };
    musicnn_prediction = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/musicnn_prediction.onnx";
      hash = "sha256-DU543UPGEK7IjAmeQfSolpeX2lrCYS6myiH6qeGkKPM=";
    };

    # CLAP teacher models (the v2.1.0 default points at model_epoch_36.onnx which
    # isn't released; we ship the teacher and pin CLAP_AUDIO_MODEL_PATH in the module)
    clap_audio = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/clap_audio_model.onnx";
      hash = "sha256-NBjHoJd4fIYzxlkQ/jVXcHHnMIS9LO6t7BnI+mC7KXY=";
    };
    clap_text = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/clap_text_model.onnx";
      hash = "sha256-IA1I85Bf8fJyr1AG3ZhR+UBxp93k6v2cB7wJxaxlpxQ=";
    };

    # HuggingFace models (BERT, RoBERTa, etc.)
    huggingface_models = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/huggingface_models.tar.gz";
      hash = "sha256-AqeNbkI0BMcnEWj3QPF+Q9vBCUf3Rt/EIFZwinRsyz0=";
    };

    # Lyrics analysis model bundle (new in v4.0.0-model)
    lyrics_model = final.fetchurl {
      url = "https://github.com/NeptuneHub/AudioMuse-AI/releases/download/v4.0.0-model/lyrics_model.tar.gz";
      hash = "sha256-mnS/mSV6xrQD+10FVEoO4yZ1i+2ybaSYTxIiIZMZUpY=";
    };

    nativeBuildInputs = [ final.gnutar final.gzip ];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/models

      # MusicNN
      cp $musicnn_embedding $out/models/musicnn_embedding.onnx
      cp $musicnn_prediction $out/models/musicnn_prediction.onnx

      # CLAP
      cp $clap_audio $out/models/clap_audio_model.onnx
      cp $clap_text $out/models/clap_text_model.onnx

      # HuggingFace cache
      mkdir -p $out/cache/huggingface
      tar -xzf $huggingface_models -C $out/cache/huggingface

      # Lyrics models — extract into the same dir AudioMuse-AI's
      # LYRICS_MODEL_DIR points at
      tar -xzf $lyrics_model -C $out/models

      runHook postInstall
    '';

    meta = with final.lib; {
      description = "ONNX models for AudioMuse-AI";
      homepage = "https://github.com/NeptuneHub/AudioMuse-AI";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };

  # Navidrome plugins — extend the upstream navidromePlugins set with our
  # AudioMuse-AI plugin. discord-rich-presence is already in upstream
  # nixos-unstable (navidromePlugins.discord-rich-presence v1.0.0).
  navidromePlugins = prev.navidromePlugins.extend (self: super: {
    audiomuse-ai = final.buildNavidromePlugin {
      pname = "audiomuse-ai";
      version = "unstable-2026-05-13";

      src = final.fetchFromGitHub {
        owner = "NeptuneHub";
        repo = "AudioMuse-AI-NV-plugin";
        rev = "66154bbdd76dd2159b70ec2ac5bc09cc57e20baf";
        hash = "sha256-8MTCyIxLaPkXGsATq44PNx2yJzgaWpp5c4hg0J+j6Yo=";
      };

      vendorHash = "sha256-mXes+doBSa5kcfHp1cuzTz30wnyyPN7NLC0iOSL8FDo=";

      meta = with final.lib; {
        description = "AudioMuse-AI plugin for Navidrome - AI-powered similar tracks";
        homepage = "https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin";
        license = licenses.mit;
      };
    };
  });

  # anyio, rq, and watchfiles test suites fail in the sandbox / with Python 3.12.15
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (python-final: python-prev: final.lib.optionalAttrs (python-prev.isPy312 or false) {
      anyio = python-prev.anyio.overridePythonAttrs (old: {
        doCheck = false;
        doInstallCheck = false;
      });
      rq = python-prev.rq.overridePythonAttrs (old: {
        doCheck = false;
        doInstallCheck = false;
      });
      watchfiles = python-prev.watchfiles.overridePythonAttrs (old: {
        doCheck = false;
        doInstallCheck = false;
      });
    })
  ];

  # Valkey (Redis fork) has flaky cluster/replication tests — skip them
  valkey = prev.valkey.overrideAttrs (old: { doCheck = false; });
}
