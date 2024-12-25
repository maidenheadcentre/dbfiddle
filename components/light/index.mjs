import {LitElement, html, css} from 'lit';

export class Light extends LitElement {
  static properties = {
    red: { type: Boolean },
  };

  static styles = css`
    span {
      display: inline-block;
      margin: 0 0.1em;
      background: #00CC00;
      border-radius: 50%;
      width: 0.7em;
      height: 0.7em;
      vertical-align: baseline;
    }
    :host([red])>span {
      background: #CC0000;
    }
  `;

  constructor() {
    super();
    this.state = true;
  }

  render() {
    return html`<span></span>`;
  }
}
customElements.define('x-light', Light);