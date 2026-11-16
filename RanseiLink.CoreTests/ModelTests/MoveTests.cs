using RanseiLink.Core.Models;
using RanseiLink.Core.Enums;

namespace RanseiLink.CoreTests.ModelTests;

public class MoveTests
{
    [Fact]
    public void AccessorsReturnCorrectValues()
    {
        Move a = new Move(new byte[]
        {
                0x43, 0x72, 0x6F, 0x73, 0x73, 0x20, 0x50, 0x6F, 0x69, 0x73, 0x6F, 0x6E, 0x00, 0x00, 0x00, 0x00,
                0xC7, 0xE4, 0xA4, 0x50, 0xFF, 0xFE, 0x5D, 0x01, 0x09, 0xC0, 0x49, 0x81, 0x09, 0x00, 0x24, 0xF3,
                0xA9, 0x42, 0x04, 0x00
        });

        a.Name.Should().Be("Cross Poison");
        a.MovementFlags.Should().Be(0);
        a.Type.Should().Be(TypeId.Poison);
        a.Power.Should().Be(38);
        a.Accuracy.Should().Be(100);
        a.Range.Should().Be(MoveRangeId.Cross);
        a.Effect1.Should().Be(MoveEffectId.ChanceToPoisonTarget);
        a.Effect1_Quantity.Should().Be(10);
        a.Effect2.Should().Be(MoveEffectId.HighCriticalHitChance);
        a.Effect2_Quantity.Should().Be(0);
        a.Rank5Effect1.Should().Be(MoveEffectId.ChanceToPoisonTarget);
        a.Rank5Effect1_Quantity.Should().Be(10);
        a.Rank5Effect2.Should().Be(MoveEffectId.HighCriticalHitChance);
        a.Rank5Effect2_Quantity.Should().Be(0);
        a.MovementAnimation.Should().Be(MoveMovementAnimationId.Default);
        a.StartupAnimation.Should().Be(MoveAnimationId.Default);
        a.ProjectileAnimation.Should().Be(MoveAnimationId.Default);
        a.ImpactAnimation.Should().Be(MoveAnimationId.WhiteImpactBubble);
        a.AdditionalAnimation.Should().Be(MoveAnimationId.QuickPurpleBeam);
        

    }

    [Fact]
    public void AccessorsSetCorrectValues()
    {
        Move a = new Move()
        {
            Name = "Cross Poison",
            MovementFlags = 0,
            Type = TypeId.Poison,
            Power = 38,
            Accuracy = 100,
            Range = MoveRangeId.Cross,
            Effect1 = MoveEffectId.ChanceToPoisonTarget,
            Effect1_Quantity = 10,
            Effect2 = MoveEffectId.HighCriticalHitChance,
            Effect2_Quantity = 5,
            Rank5Effect1 = MoveEffectId.ChanceToPoisonTarget,
            Rank5Effect1_Quantity = 10,
            Rank5Effect2 = MoveEffectId.HighCriticalHitChance,
            Rank5Effect2_Quantity = 8,
            MovementAnimation = MoveMovementAnimationId.FieryDance,
            StartupAnimation = MoveAnimationId.OrangeOrbBurst,
            ProjectileAnimation = MoveAnimationId.OrbBlackHole,
            ImpactAnimation = MoveAnimationId.PurpleCrescentBubble,
            AdditionalAnimation = MoveAnimationId.BlackClawMarks,
        };

        a.Name.Should().Be("Cross Poison");
        a.MovementFlags.Should().Be(0);
        a.Type.Should().Be(TypeId.Poison);
        a.Power.Should().Be(38);
        a.Accuracy.Should().Be(100);
        a.Range.Should().Be(MoveRangeId.Cross);
        a.Effect1.Should().Be(MoveEffectId.ChanceToPoisonTarget);
        a.Effect1_Quantity.Should().Be(10);
        a.Effect2.Should().Be(MoveEffectId.HighCriticalHitChance);
        a.Effect2_Quantity.Should().Be(5);
        a.Rank5Effect1.Should().Be(MoveEffectId.ChanceToPoisonTarget);
        a.Rank5Effect1_Quantity.Should().Be(10);
        a.Rank5Effect2.Should().Be(MoveEffectId.HighCriticalHitChance);
        a.Rank5Effect2_Quantity.Should().Be(8);
        a.MovementAnimation.Should().Be(MoveMovementAnimationId.FieryDance);
        a.StartupAnimation.Should().Be(MoveAnimationId.OrangeOrbBurst);
        a.ProjectileAnimation.Should().Be(MoveAnimationId.OrbBlackHole);
        a.ImpactAnimation.Should().Be(MoveAnimationId.PurpleCrescentBubble);
        a.AdditionalAnimation.Should().Be(MoveAnimationId.BlackClawMarks);

        // Add Array equal test when possible
    }
}
