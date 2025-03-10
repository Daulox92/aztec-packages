import { PeerErrorSeverity } from '@aztec/circuit-types';

import { jest } from '@jest/globals';
import { type PeerId } from '@libp2p/interface';
import { type MockProxy, mock } from 'jest-mock-extended';

import { type PeerScoring } from '../../peer-manager/peer_scoring.js';
import { ReqRespSubProtocol, type ReqRespSubProtocolRateLimits } from '../interface.js';
import { RequestResponseRateLimiter } from './rate_limiter.js';

class MockPeerId {
  private id: string;
  constructor(id: string) {
    this.id = id;
  }
  public toString(): string {
    return this.id;
  }
}

const makePeer = (id: string): PeerId => {
  return new MockPeerId(id) as unknown as PeerId;
};

describe('rate limiter', () => {
  let rateLimiter: RequestResponseRateLimiter;
  let peerScoring: MockProxy<PeerScoring>;

  beforeEach(() => {
    jest.useFakeTimers();
    const config = {
      [ReqRespSubProtocol.TX]: {
        // One request every 200ms
        peerLimit: {
          quotaCount: 5,
          quotaTimeMs: 1000,
        },
        // One request every 100ms
        globalLimit: {
          quotaCount: 10,
          quotaTimeMs: 1000,
        },
      },
    } as ReqRespSubProtocolRateLimits; // force type as we will not provide descriptions of all protocols

    peerScoring = mock<PeerScoring>();

    rateLimiter = new RequestResponseRateLimiter(peerScoring, config);
  });

  afterEach(() => {
    jest.useRealTimers();
    rateLimiter.stop();
  });

  it('Should allow requests within a peer limit', () => {
    const peerId = makePeer('peer1');
    // Expect to allow a burst of 5, then not allow
    for (let i = 0; i < 5; i++) {
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(false);

    // Smooth requests
    for (let i = 0; i < 5; i++) {
      jest.advanceTimersByTime(200);
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(false);

    // Reset after quota has passed
    jest.advanceTimersByTime(1000);
    // Second burst
    for (let i = 0; i < 5; i++) {
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(false);

    // Spy on the peer manager and check that penalizePeer is called
    expect(peerScoring.penalizePeer).toHaveBeenCalledWith(peerId, PeerErrorSeverity.MidToleranceError);
  });

  it('Should allow requests within the global limit', () => {
    // Initial burst
    const falingPeer = makePeer('nolettoinno');
    for (let i = 0; i < 10; i++) {
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, makePeer(`peer${i}`))).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, falingPeer)).toBe(false);

    // Smooth requests
    for (let i = 0; i < 10; i++) {
      jest.advanceTimersByTime(100);
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, makePeer(`peer${i}`))).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, falingPeer)).toBe(false);

    // Reset after quota has passed
    jest.advanceTimersByTime(1000);
    // Second burst
    for (let i = 0; i < 10; i++) {
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, makePeer(`peer${i}`))).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, falingPeer)).toBe(false);
  });

  it('Should reset after quota has passed', () => {
    const peerId = makePeer('peer1');
    for (let i = 0; i < 5; i++) {
      expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(true);
    }
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(false);
    jest.advanceTimersByTime(1000);
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(true);
  });

  it('Should handle multiple protocols separately', () => {
    const config = {
      [ReqRespSubProtocol.TX]: {
        peerLimit: {
          quotaCount: 5,
          quotaTimeMs: 1000,
        },
        globalLimit: {
          quotaCount: 10,
          quotaTimeMs: 1000,
        },
      },
      [ReqRespSubProtocol.PING]: {
        peerLimit: {
          quotaCount: 2,
          quotaTimeMs: 1000,
        },
        globalLimit: {
          quotaCount: 4,
          quotaTimeMs: 1000,
        },
      },
    } as ReqRespSubProtocolRateLimits;
    const multiProtocolRateLimiter = new RequestResponseRateLimiter(peerScoring, config);

    const peerId = makePeer('peer1');

    // Protocol 1
    for (let i = 0; i < 5; i++) {
      expect(multiProtocolRateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(true);
    }
    expect(multiProtocolRateLimiter.allow(ReqRespSubProtocol.TX, peerId)).toBe(false);

    // Protocol 2
    for (let i = 0; i < 2; i++) {
      expect(multiProtocolRateLimiter.allow(ReqRespSubProtocol.PING, peerId)).toBe(true);
    }
    expect(multiProtocolRateLimiter.allow(ReqRespSubProtocol.PING, peerId)).toBe(false);

    multiProtocolRateLimiter.stop();
  });

  it('Should allow requests if no rate limiter is configured', () => {
    const rateLimiter = new RequestResponseRateLimiter(peerScoring, {} as ReqRespSubProtocolRateLimits);
    expect(rateLimiter.allow(ReqRespSubProtocol.TX, makePeer('peer1'))).toBe(true);
  });

  it('Should smooth out spam', () => {
    const requests = 1000;
    const peers = 100;
    let allowedRequests = 0;

    for (let i = 0; i < requests; i++) {
      const peerId = makePeer(`peer${i % peers}`);
      if (rateLimiter.allow(ReqRespSubProtocol.TX, peerId)) {
        allowedRequests++;
      }
      jest.advanceTimersByTime(5);
    }
    // With 1000 iterations of 5ms per iteration, we run over 5 seconds
    // With the configuration of 5 requests per second per peer and 10 requests per second globally, we expect:
    // most of the allowed request to come through the global limit
    // This sets a floor of 50 requests per second, but allowing for the initial burst, we expect there to be upto an additional 10 requests

    // (upon running a few times we actually see 59)
    const expectedRequestsFloor = 50;
    const expectedRequestsCeiling = 60;
    expect(allowedRequests).toBeGreaterThan(expectedRequestsFloor);
    expect(allowedRequests).toBeLessThan(expectedRequestsCeiling);
  });
});
