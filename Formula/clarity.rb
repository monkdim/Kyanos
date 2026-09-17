class Clarity < Formula
  desc "Simple code. Real power. A modern programming language."
  homepage "https://github.com/monkdim/Kyanos"
  version "1.0.1"
  license "GPL-3.0-only"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/monkdim/Kyanos/releases/download/v#{version}/clarity-darwin-arm64.tar.gz"
      sha256 "dafe5b29f2441163b138339af449b9473c72d3fae9e51c70131521d554e89870"
    else
      url "https://github.com/monkdim/Kyanos/releases/download/v#{version}/clarity-darwin-x64.tar.gz"
      sha256 "077b555d076b924ffa37ac45ee3ce09de41473dc1ad0a060585b751242c84041"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/monkdim/Kyanos/releases/download/v#{version}/clarity-linux-arm64.tar.gz"
      sha256 "40a16442335bfbc2d725e9e476f8db701ebe1b756c691d3a01557d611da6fd15"
    else
      url "https://github.com/monkdim/Kyanos/releases/download/v#{version}/clarity-linux-x64.tar.gz"
      sha256 "0bb35e3f9a2e217438fcd6eeecd16b98ec0f9bcc6a05488c934c514559ecc9dd"
    end
  end

  def install
    bin.install "clarity"
  end

  test do
    assert_match "1.0.1", shell_output("#{bin}/clarity version")
  end
end
