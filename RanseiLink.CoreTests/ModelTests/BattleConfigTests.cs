using RanseiLink.Core.Enums;
using RanseiLink.Core.Maps;
using RanseiLink.Core.Models;
using RanseiLink.Core.Graphics;

namespace RanseiLink.CoreTests.ModelTests;

public class BattleConfigTests
{
    [Fact]
    public void AccessorsReturnCorrectValues()
    {
        BattleConfig a = new BattleConfig(new byte[]
        {
            0x01, 0xB8, 0x68, 0x7C, 0x4D, 0x80, 0x33, 0x02, 0x00, 0x80, 0xA4, 0x14, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x0E, 0x00, 0x0E, 0x00, 0x00, 0x00
        });

        a.MapId.Should().Be(new MapId(1, 0));
        a.UpperSkyColor.Should().Be(new Rgb15(23, 8, 3));
        a.MiddleSkyColor.Should().Be(new Rgb15(13, 2, 0));
        a.LowerSkyColor.Should().Be(new Rgb15(7, 3, 1));
        a.VictoryCondition.Should().Be((BattleVictoryConditionFlags)0 /* former "DefeatAllEnemies" = no flags */);
        a.DefeatCondition.Should().Be((BattleVictoryConditionFlags)0 /* former "DefeatAllEnemies" = no flags */);
        a.NumberOfTurns.Should().Be(20);
    }

    [Fact]
    public void AccessorsSetCorrectValues()
    {
        BattleConfig a = new BattleConfig()
        {
            MapId = new MapId(10, 1),
            UpperSkyColor = new Rgb15(9, 7, 21),
            MiddleSkyColor = new Rgb15(20, 19, 16),
            LowerSkyColor = new Rgb15(12, 11, 1),
            VictoryCondition = BattleVictoryConditionFlags.ClaimAllBanners | BattleVictoryConditionFlags.HoldAllBannersFor5Turns,
            DefeatCondition = BattleVictoryConditionFlags.ClaimAllBanners,
            NumberOfTurns = 17
        };

        a.MapId.Should().Be(new MapId(10, 1));
        a.UpperSkyColor.Should().Be(new Rgb15(9, 7, 21));
        a.MiddleSkyColor.Should().Be(new Rgb15(20, 19, 16));
        a.LowerSkyColor.Should().Be(new Rgb15(12, 11, 1));
        a.VictoryCondition.Should().Be(BattleVictoryConditionFlags.ClaimAllBanners | BattleVictoryConditionFlags.HoldAllBannersFor5Turns);
        a.DefeatCondition.Should().Be(BattleVictoryConditionFlags.ClaimAllBanners);
        a.NumberOfTurns.Should().Be(17);
    }
}
