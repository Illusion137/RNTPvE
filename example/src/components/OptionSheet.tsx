import SegmentedControl from '@react-native-segmented-control/segmented-control';
import React, { useState } from 'react';
import { Platform, StyleSheet, Text, View } from 'react-native';
import TrackPlayer, {
  AppKilledPlaybackBehavior,
  Capability,
  RepeatMode,
} from 'react-native-track-player';
import { DefaultAudioServiceBehaviour, DefaultRepeatMode } from '../services';
import { Spacer } from './Spacer';
import { BottomSheetScrollView } from '@gorhom/bottom-sheet';
import { Button } from './Button';
import Slider from '@react-native-community/slider';

export const OptionStack: React.FC<{
  children: React.ReactNode;
  vertical?: boolean;
}> = ({ children, vertical }) => {
  const childrenArray = React.Children.toArray(children);

  return (
    <View style={vertical ? styles.optionColumn : styles.optionRow}>
      {childrenArray.map((child, index) => (
        <View key={index}>{child}</View>
      ))}
    </View>
  );
};

export const OptionSheet: React.FC = () => {
  const [selectedRepeatMode, setSelectedRepeatMode] = useState(
    repeatModeToIndex(DefaultRepeatMode)
  );

  const [selectedAudioServiceBehaviour, setSelectedAudioServiceBehaviour] =
    useState(audioServiceBehaviourToIndex(DefaultAudioServiceBehaviour));
  const [crossfadeDuration, setCrossfadeDuration] = useState(0);
  const [equalizerBands, setEqualizerBands] = useState<number[]>([
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ]);

  return (
    <BottomSheetScrollView contentContainerStyle={styles.contentContainer}>
      <OptionStack vertical={true}>
        <Text style={styles.optionRowLabel}>Repeat Mode</Text>
        <Spacer />
        <SegmentedControl
          appearance={'dark'}
          values={['Off', 'Track', 'Queue']}
          selectedIndex={selectedRepeatMode}
          onChange={async (event) => {
            setSelectedRepeatMode(event.nativeEvent.selectedSegmentIndex);
            const repeatMode = repeatModeFromIndex(
              event.nativeEvent.selectedSegmentIndex
            );
            await TrackPlayer.setRepeatMode(repeatMode);
          }}
        />
      </OptionStack>
      <Spacer />
      {Platform.OS === 'android' && (
        <OptionStack vertical={true}>
          <Text style={styles.optionRowLabel}>Audio Service on App Kill</Text>
          <Spacer />
          <SegmentedControl
            appearance={'dark'}
            values={['Continue', 'Pause', 'Stop & Remove']}
            selectedIndex={selectedAudioServiceBehaviour}
            onChange={async (event) => {
              setSelectedAudioServiceBehaviour(
                event.nativeEvent.selectedSegmentIndex
              );
              const appKilledPlaybackBehavior = audioServiceBehaviourFromIndex(
                event.nativeEvent.selectedSegmentIndex
              );

              // TODO: Copied from example/src/services/SetupService.tsx until updateOptions
              // allows for partial updates (i.e. only android.appKilledPlaybackBehavior).
              await TrackPlayer.updateOptions({
                android: {
                  appKilledPlaybackBehavior,
                },
                capabilities: [
                  Capability.Play,
                  Capability.Pause,
                  Capability.SkipToNext,
                  Capability.SkipToPrevious,
                  Capability.SeekTo,
                ],
                progressUpdateEventInterval: 2,
              });
            }}
          />
        </OptionStack>
      )}
      {Platform.OS === 'ios' && (
        <>
          <Spacer />
          <OptionStack vertical={true}>
            <Text style={styles.optionRowLabel}>Crossfade Duration</Text>
            <Spacer />
            <Text style={styles.sliderLabel}>
              {crossfadeDuration.toFixed(1)} seconds
            </Text>
            <Slider
              style={styles.slider}
              minimumValue={0}
              maximumValue={10}
              value={crossfadeDuration}
              onValueChange={(value) => {
                setCrossfadeDuration(value);
                TrackPlayer.setCrossFade(value);
              }}
              minimumTrackTintColor="#1DB954"
              maximumTrackTintColor="#333333"
            />
            <Text style={styles.sliderHint}>Set to 0 to disable crossfade</Text>
          </OptionStack>
          <Spacer />
          <OptionStack vertical={true}>
            <Text style={styles.optionRowLabel}>10-Band Equalizer</Text>
            <Text style={styles.sliderHint}>
              Frequencies: 31, 62, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz
            </Text>
            <Spacer />
            <View style={styles.equalizerContainer}>
              {equalizerBands.map((band, index) => (
                <View key={index} style={styles.equalizerBand}>
                  <Text style={styles.equalizerValue}>{band.toFixed(0)}dB</Text>
                  <Slider
                    tapToSeek={true}
                    style={styles.equalizerSlider}
                    minimumValue={-24}
                    maximumValue={24}
                    value={band}
                    onValueChange={(value) => {
                      const newBands = [...equalizerBands];
                      newBands[index] = value;
                      setEqualizerBands(newBands);
                      TrackPlayer.setEqualizer(newBands);
                    }}
                    minimumTrackTintColor="#1DB954"
                    maximumTrackTintColor="#333333"
                  />
                </View>
              ))}
            </View>
            <Spacer />
            <Button
              title="Reset Equalizer"
              onPress={async () => {
                const resetBands = new Array(10).fill(0);
                setEqualizerBands(resetBands);
                await TrackPlayer.removeEqualizer();
              }}
              type="primary"
            />
          </OptionStack>
        </>
      )}
    </BottomSheetScrollView>
  );
};

const styles = StyleSheet.create({
  contentContainer: {
    flex: 1,
    backgroundColor: 'black',
    marginTop: '4%',
    marginHorizontal: 16,
    zIndex: 1000,
  },
  optionRow: {
    width: '100%',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  optionColumn: {
    width: '100%',
    flexDirection: 'column',
  },
  optionRowLabel: {
    color: 'white',
    fontSize: 20,
    fontWeight: '600',
  },
  slider: {
    width: '100%',
    height: 40,
  },
  sliderLabel: {
    color: 'white',
    fontSize: 16,
    marginBottom: 8,
  },
  sliderHint: {
    color: '#999',
    fontSize: 12,
    marginTop: 4,
  },
  equalizerContainer: {
    height: 200,
    width: '100%',
    paddingHorizontal: 8,
  },
  equalizerBand: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'flex-end',
    marginHorizontal: 2,
  },
  equalizerSlider: {
    width: '100%',
    height: 30,
  },
  equalizerLabel: {
    color: 'white',
    fontSize: 10,
    marginTop: 4,
  },
  equalizerValue: {
    color: '#1DB954',
    fontSize: 9,
    marginBottom: 2,
  },
});

const repeatModeFromIndex = (index: number): RepeatMode => {
  switch (index) {
    case 0:
      return RepeatMode.Off;
    case 1:
      return RepeatMode.Track;
    case 2:
      return RepeatMode.Queue;
    default:
      return RepeatMode.Off;
  }
};

const repeatModeToIndex = (repeatMode: RepeatMode): number => {
  switch (repeatMode) {
    case RepeatMode.Off:
      return 0;
    case RepeatMode.Track:
      return 1;
    case RepeatMode.Queue:
      return 2;
    default:
      return 0;
  }
};

const audioServiceBehaviourFromIndex = (
  index: number
): AppKilledPlaybackBehavior => {
  switch (index) {
    case 0:
      return AppKilledPlaybackBehavior.ContinuePlayback;
    case 1:
      return AppKilledPlaybackBehavior.PausePlayback;
    case 2:
      return AppKilledPlaybackBehavior.StopPlaybackAndRemoveNotification;
    default:
      return AppKilledPlaybackBehavior.ContinuePlayback;
  }
};

const audioServiceBehaviourToIndex = (
  audioServiceBehaviour: AppKilledPlaybackBehavior
): number => {
  switch (audioServiceBehaviour) {
    case AppKilledPlaybackBehavior.ContinuePlayback:
      return 0;
    case AppKilledPlaybackBehavior.PausePlayback:
      return 1;
    case AppKilledPlaybackBehavior.StopPlaybackAndRemoveNotification:
      return 2;
    default:
      return 0;
  }
};
