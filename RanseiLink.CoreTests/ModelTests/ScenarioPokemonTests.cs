using RanseiLink.Core.Models;
using RanseiLink.Core.Enums;

namespace RanseiLink.CoreTests.ModelTests;

public class ScenarioPokemonTests
{
    [Fact]
    public void AccessorsReturnCorrectValues()
    {
        ScenarioPokemon a = new ScenarioPokemon(new byte[]
        {
            0x14, 0x00, 0xFC, 0x03, 0xEF, 0xBD, 0x97, 0x04
        });

        a.Pokemon.Should().Be(PokemonId.Jigglypuff);
        a.Ability.Should().Be(AbilityId.Lullaby);
        a.HpIv.Should().Be(15);
        a.AtkIv.Should().Be(15);
        a.DefIv.Should().Be(15);
        a.SpeIv.Should().Be(15);
        a.Exp.Should().Be(510); // Models.xml (commit 11e8f03) moved Exp to bits 17-31; was 1020 under the old 16-31 layout
    }

    [Fact]
    public void AccessorsSetCorrectValues()
    {
        ScenarioPokemon a = new ScenarioPokemon
        {
            Pokemon = PokemonId.Jigglypuff,
            Ability = AbilityId.Lullaby,
            HpIv = 15,
            AtkIv = 15,
            DefIv = 15,
            SpeIv = 15,
            Exp = 510
        };

        var expected = new byte[]
        {
            0x14, 0x00, 0xFC, 0x03, 0xEF, 0xBD, 0x97, 0x04
        };

        a.Pokemon.Should().Be(PokemonId.Jigglypuff);
        a.Ability.Should().Be(AbilityId.Lullaby);
        a.HpIv.Should().Be(15);
        a.AtkIv.Should().Be(15);
        a.DefIv.Should().Be(15);
        a.SpeIv.Should().Be(15);
        a.Exp.Should().Be(510); // Models.xml (commit 11e8f03) moved Exp to bits 17-31; was 1020 under the old 16-31 layout

        a.Data.Should().Equal(expected);
    }
}
